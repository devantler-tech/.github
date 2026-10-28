// Package publication publishes one missing GitHub release for an existing stable tag.
//
// It re-admits the incident through the inspector's GET-only admission, proves the writer
// credential can push, takes a complete release inventory twice, re-admits immediately
// before writing, then sends at most one create-release request and reads the result back
// independently. It never creates or moves a tag, uploads assets, publishes generated notes,
// or changes which release is latest. It never retries the write: an unknown outcome fails,
// and a later explicit run reconciles through fresh reads.
package publication

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"reflect"
	"time"

	"github.com/devantler-tech/dotgithub/inspect-release-recovery/internal/inspection"
)

const apiURL = "https://api.github.com"

// maxPages bounds the release inventory. Long-lived repositories here already exceed a
// thousand releases; a repository beyond this bound is refused rather than read partially.
// Pages stay small because each listed release carries its full notes, and every response
// is capped at one mebibyte.
const maxPages = 200
const pageSize = 25

// unknownOutcome is how every failure that may follow an accepted write ends.
const unknownOutcome = "do not publish by hand or retry; run recovery again to reconcile"

type publisher struct {
	reader *inspection.Reader
	client *http.Client
	base   string
}

func newPublisher(client *http.Client, base string) *publisher {
	return &publisher{reader: inspection.NewReader(client, base), client: inspection.HardenedClient(client), base: base}
}

func object(value any) map[string]any { result, _ := value.(map[string]any); return result }

func text(value any) string { result, _ := value.(string); return result }

// Receipt is the deterministic release body. It states what the recovery did and did not do.
func Receipt(a *inspection.Admission) string {
	return "Recovered GitHub release for the existing tag " + a.Tag + " at " + a.SourceSHA + ".\n\n" +
		"- Original release run: https://github.com/" + a.Repository + "/actions/runs/" + a.RunID + "/attempts/" + a.RunAttempt + "\n" +
		"- Release producer: " + a.ProducerRef + "\n\n" +
		"The original run pushed this tag but did not publish its GitHub release. " +
		"This release was published later by the release-recovery publisher. " +
		"The original generated release notes were not reconstructed.\n"
}

// releaseRecord keeps only the inventory fields that decide whether publication is safe.
type releaseRecord struct {
	ID         string
	Tag        string
	Prerelease bool
}

type inventory struct {
	Releases []releaseRecord
	Latest   string // the latest release's id, or "" when the repository has none
}

// capability proves Contents write with GitHub's permission-gated, non-persisting preview.
// Repository permissions describe a role and cannot establish a granular token's authority.
// Draft visibility depends on this proof. The preview targets a separate probe tag at the
// admitted default branch; its content is discarded, never used to reconstruct release notes.
func (p *publisher) capability(ctx context.Context, a *inspection.Admission, token string) error {
	value, _, err := p.reader.Get(ctx, "/repos/"+a.Repository, token, false)
	if err != nil {
		return fmt.Errorf("writer repository read: %w", err)
	}
	repo := object(value)
	if repo["full_name"] != a.Repository || repo["default_branch"] != a.DefaultBranch ||
		repo["visibility"] != "public" || repo["private"] != false || repo["archived"] != false || repo["disabled"] != false {
		return errors.New("writer repository no longer matches the admitted public repository")
	}
	// GitHub documents generate-notes as requiring Contents write and saving no content:
	// https://docs.github.com/en/rest/releases/releases#generate-release-notes-content-for-a-release
	payload, err := json.Marshal(map[string]string{
		"tag_name": "release-recovery-capability-probe", "target_commitish": a.DefaultBranch,
	})
	if err != nil {
		return errors.New("could not encode the writer capability request")
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, p.base+"/repos/"+a.Repository+"/releases/generate-notes", bytes.NewReader(payload))
	if err != nil {
		return errors.New("invalid fixed writer capability request")
	}
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	request.Header.Set("Content-Type", "application/json")
	response, err := p.client.Do(request)
	if err != nil {
		return errors.New("writer capability request failed")
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("writer capability was refused with status %d", response.StatusCode)
	}
	value, err = inspection.ReadJSONBody(response)
	if err != nil {
		return fmt.Errorf("writer capability response is unreadable: %w", err)
	}
	preview := object(value)
	_, bodyOK := preview["body"].(string)
	if text(preview["name"]) == "" || !bodyOK {
		return errors.New("writer capability response is malformed")
	}
	return nil
}

// latest reads the latest-release anchor; a repository may have none.
func (p *publisher) latest(ctx context.Context, a *inspection.Admission, token string) (string, error) {
	value, present, err := p.reader.Get(ctx, "/repos/"+a.Repository+"/releases/latest", token, true)
	if err != nil {
		return "", fmt.Errorf("latest release: %w", err)
	}
	if !present {
		return "", nil
	}
	release := object(value)
	id, ok := inspection.PositiveID(release["id"])
	if !ok || release["draft"] != false || release["prerelease"] != false || text(release["tag_name"]) == "" {
		return "", errors.New("latest release is not a published stable release")
	}
	return id, nil
}

// list reads every release page and the latest anchor. A draft that names this tag, or no
// tag at all, is refused: it may be an interrupted publication of this release, and it is
// visible only because push access was proven. Drafts for other tags are not this incident.
func (p *publisher) list(ctx context.Context, a *inspection.Admission, token string) (inventory, error) {
	var result inventory
	complete := false
	for page := 1; page <= maxPages && !complete; page++ {
		value, _, err := p.reader.Get(ctx, fmt.Sprintf("/repos/%s/releases?per_page=%d&page=%d", a.Repository, pageSize, page), token, false)
		if err != nil {
			return result, fmt.Errorf("release inventory: %w", err)
		}
		entries, ok := value.([]any)
		if !ok || len(entries) > pageSize {
			return result, errors.New("release inventory page is malformed")
		}
		for _, entry := range entries {
			release := object(entry)
			id, idOK := inspection.PositiveID(release["id"])
			draft, draftOK := release["draft"].(bool)
			prerelease, prereleaseOK := release["prerelease"].(bool)
			tag, tagOK := release["tag_name"].(string)
			if !idOK || !draftOK || !prereleaseOK || !tagOK {
				return result, errors.New("release inventory has a malformed record")
			}
			if draft && (tag == a.Tag || tag == "") {
				return result, errors.New("a draft release for this tag, or with no tag, exists; resolve it before recovery")
			}
			if !draft {
				result.Releases = append(result.Releases, releaseRecord{ID: id, Tag: tag, Prerelease: prerelease})
			}
		}
		complete = len(entries) < pageSize
	}
	if !complete {
		return result, errors.New("release inventory exceeds the supported bound")
	}
	latest, err := p.latest(ctx, a, token)
	result.Latest = latest
	return result, err
}

// stableInventory requires two complete inventories to agree before anything is written.
func (p *publisher) stableInventory(ctx context.Context, a *inspection.Admission, token string) (inventory, error) {
	first, err := p.list(ctx, a, token)
	if err != nil {
		return first, err
	}
	second, err := p.list(ctx, a, token)
	if err != nil {
		return second, err
	}
	if !reflect.DeepEqual(first, second) {
		return first, errors.New("release inventory changed between independent reads")
	}
	for _, release := range first.Releases {
		if release.Tag == a.Tag {
			return first, errors.New("a release record for this tag exists but admission found no matching publication")
		}
	}
	return first, nil
}

// requested is the release this run asks GitHub to publish. The create response and the
// readback are compared against every one of these fields, so none can drift unnoticed.
func requested(a *inspection.Admission) map[string]any {
	return map[string]any{"tag_name": a.Tag, "name": a.Tag, "body": Receipt(a), "draft": false, "prerelease": false}
}

// matches reports whether a release carries every requested field exactly.
func matches(release map[string]any, want map[string]any) bool {
	for key, value := range want {
		if !reflect.DeepEqual(release[key], value) {
			return false
		}
	}
	return release != nil
}

// create sends the single create-release request. It is never retried.
func (p *publisher) create(ctx context.Context, a *inspection.Admission, token string) (string, error) {
	fields := requested(a)
	fields["target_commitish"] = a.SourceSHA
	fields["generate_release_notes"] = false
	// The endpoint's make_latest is a string enum; anything else defaults to "true".
	fields["make_latest"] = "false"
	payload, err := json.Marshal(fields)
	if err != nil {
		return "", errors.New("could not encode the publication request")
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, p.base+"/repos/"+a.Repository+"/releases", bytes.NewReader(payload))
	if err != nil {
		return "", errors.New("invalid fixed API request")
	}
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	request.Header.Set("Content-Type", "application/json")
	response, err := p.client.Do(request)
	if err != nil {
		return "", errors.New("publication outcome is unknown after a failed request; " + unknownOutcome)
	}
	defer response.Body.Close()
	value, readErr := inspection.ReadJSONBody(response)
	switch {
	case response.StatusCode >= 500:
		// A gateway or server error can follow a release GitHub already created.
		return "", fmt.Errorf("publication outcome is unknown after status %d; %s", response.StatusCode, unknownOutcome)
	case response.StatusCode != http.StatusCreated:
		return "", fmt.Errorf("publication was refused with status %d", response.StatusCode)
	case readErr != nil:
		return "", fmt.Errorf("publication response is unreadable: %v; %s", readErr, unknownOutcome)
	}
	release := object(value)
	id, ok := inspection.PositiveID(release["id"])
	if !ok || !matches(release, requested(a)) {
		return "", errors.New("publication response does not describe the requested release; " + unknownOutcome)
	}
	return id, nil
}

// observation is what verification read back after the write. Every reported fact comes from it.
type observation struct {
	LatestBefore, LatestAfter string
}

// verify re-reads the release, the admitted identity, the inventory and the latest anchor.
func (p *publisher) verify(ctx context.Context, args []string, a *inspection.Admission, token, id string, before inventory) (observation, error) {
	seen := observation{LatestBefore: before.Latest}
	value, present, err := p.reader.Get(ctx, "/repos/"+a.Repository+"/releases/tags/"+a.Tag, token, true)
	if err != nil {
		return seen, fmt.Errorf("publication readback: %w", err)
	}
	release := object(value)
	readID, _ := inspection.PositiveID(release["id"])
	commitish := text(release["target_commitish"])
	if !present || readID != id || !matches(release, requested(a)) || commitish != a.SourceSHA && commitish != a.DefaultBranch {
		return seen, errors.New("publication readback does not match the requested release")
	}
	after, err := p.reader.Admit(ctx, args, token)
	if err != nil {
		return seen, fmt.Errorf("post-publication admission: %w", err)
	}
	if !a.SameIdentity(after) || !after.Published {
		return seen, errors.New("post-publication observation does not match the admitted tag and source")
	}
	// The release list must now hold exactly this release for the tag, and no new draft.
	now, err := p.list(ctx, a, token)
	if err != nil {
		return seen, fmt.Errorf("post-publication inventory: %w", err)
	}
	records := 0
	for _, record := range now.Releases {
		if record.Tag == a.Tag {
			records++
			if record.ID != id {
				return seen, errors.New("another release record for this tag appeared during publication")
			}
		}
	}
	if records != 1 {
		return seen, errors.New("post-publication inventory does not hold exactly the published release")
	}
	seen.LatestAfter = now.Latest
	// make_latest "false" keeps an existing latest release in place. With no earlier stable
	// release there is nothing to preserve, and GitHub may report the new one as latest.
	if now.Latest != before.Latest && (before.Latest != "" || now.Latest != id) {
		return seen, errors.New("the latest release changed during publication")
	}
	return seen, nil
}

// report prints the result. A no-op inspected only that a matching release exists, so it
// claims nothing else; a publication reports what verification observed.
func report(out io.Writer, a *inspection.Admission, id string, seen *observation) error {
	fields := map[string]any{"result": "already-published", "repository": a.Repository, "tag": a.Tag,
		"source_sha": a.SourceSHA, "run_id": a.RunID, "run_attempt": a.RunAttempt, "producer_ref": a.ProducerRef,
		"release_id": "", "publication_requests": 0, "release_record": "not-inspected",
		"latest_release_before": "not-inspected", "latest_release_after": "not-inspected"}
	if seen != nil {
		// The verified record carries the receipt body, never the discarded capability preview.
		fields["result"], fields["release_id"], fields["publication_requests"] = "published", id, 1
		fields["release_record"] = "matches-request"
		fields["latest_release_before"], fields["latest_release_after"] = seen.LatestBefore, seen.LatestAfter
	}
	raw, err := json.Marshal(fields)
	if err != nil {
		return errors.New("could not encode the result")
	}
	_, err = out.Write(append(raw, '\n'))
	return err
}

// run publishes the missing release, or reports that a matching one already exists.
func run(args []string, token string, out io.Writer, p *publisher) error {
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Second)
	defer cancel()
	admission, err := p.reader.Admit(ctx, args, token)
	if err != nil {
		return err
	}
	if admission.Published {
		return report(out, admission, "", nil)
	}
	if err := p.capability(ctx, admission, token); err != nil {
		return err
	}
	before, err := p.stableInventory(ctx, admission, token)
	if err != nil {
		return err
	}
	again, err := p.reader.Admit(ctx, args, token)
	if err != nil {
		return fmt.Errorf("re-admission: %w", err)
	}
	if !admission.SameIdentity(again) {
		return errors.New("re-admission observed a different tag, source or configuration")
	}
	if again.Published {
		return report(out, again, "", nil)
	}
	id, err := p.create(ctx, again, token)
	if err != nil {
		return err
	}
	// Verification gets its own deadline so a slow admission cannot starve the readback.
	verifyCtx, cancelVerify := context.WithTimeout(context.Background(), 150*time.Second)
	defer cancelVerify()
	seen, err := p.verify(verifyCtx, args, again, token, id, before)
	if err != nil {
		return fmt.Errorf("release %s was created but its verification failed: %v; %s", id, err, unknownOutcome)
	}
	if err := report(out, again, id, &seen); err != nil {
		return fmt.Errorf("release %s was published and verified, but the result could not be written: %v; do not publish it again", id, err)
	}
	return nil
}

// Run publishes against the fixed production API with the supplied writer credential.
func Run(args []string, token string, out io.Writer) error {
	return run(args, token, out, newPublisher(nil, apiURL))
}
