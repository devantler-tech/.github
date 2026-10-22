// Package publication publishes one missing GitHub release for an existing stable tag.
//
// It re-admits the incident through the inspector's GET-only admission, proves the writer
// credential can push, takes a complete release inventory twice, re-admits immediately
// before writing, then sends at most one create-release request and reads the result back
// independently. It never creates or moves a tag, uploads assets, generates notes, or
// changes which release is latest. It never retries the write: an unknown outcome fails,
// and a later explicit run reconciles through fresh reads.
package publication

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"reflect"
	"strconv"
	"time"

	"github.com/devantler-tech/dotgithub/inspect-release-recovery/internal/inspection"
)

const apiURL = "https://api.github.com"
const maxResponse = 1 << 20

// maxPages bounds the release inventory; a repository with more releases is refused.
const maxPages = 10
const pageSize = 100

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

func positiveID(value any) (string, bool) {
	number, ok := value.(json.Number)
	if !ok {
		return "", false
	}
	n, err := strconv.ParseUint(string(number), 10, 64)
	return string(number), err == nil && n > 0 && strconv.FormatUint(n, 10) == string(number)
}

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
	Draft      bool
	Prerelease bool
}

type inventory struct {
	Releases []releaseRecord
	Latest   string // the latest release's id, or "" when the repository has none
}

// capability proves, with the writer credential, that it can push to the exact repository.
// Draft releases are visible only with push access, so the inventory depends on this proof.
func (p *publisher) capability(ctx context.Context, a *inspection.Admission, token string) error {
	value, _, err := p.reader.Get(ctx, "/repos/"+a.Repository, token, false)
	if err != nil {
		return fmt.Errorf("writer repository read: %w", err)
	}
	repo := object(value)
	if repo["full_name"] != a.Repository || object(repo["permissions"])["push"] != true {
		return errors.New("writer credential has no proven push access to the repository")
	}
	return nil
}

// list reads every release page and the latest anchor. Any draft is refused: a draft could be
// an interrupted publication of this tag, and it is visible only because push access was proven.
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
			id, idOK := positiveID(release["id"])
			draft, draftOK := release["draft"].(bool)
			prerelease, prereleaseOK := release["prerelease"].(bool)
			if !idOK || !draftOK || !prereleaseOK || text(release["tag_name"]) == "" && !draft {
				return result, errors.New("release inventory has a malformed record")
			}
			if draft {
				return result, errors.New("a draft release exists; resolve it before recovery")
			}
			result.Releases = append(result.Releases, releaseRecord{ID: id, Tag: text(release["tag_name"]), Draft: draft, Prerelease: prerelease})
		}
		complete = len(entries) < pageSize
	}
	if !complete {
		return result, errors.New("release inventory exceeds the supported bound")
	}
	value, present, err := p.reader.Get(ctx, "/repos/"+a.Repository+"/releases/latest", token, true)
	if err != nil {
		return result, fmt.Errorf("latest release: %w", err)
	}
	if present {
		latest := object(value)
		id, ok := positiveID(latest["id"])
		if !ok || latest["draft"] != false || latest["prerelease"] != false || text(latest["tag_name"]) == "" {
			return result, errors.New("latest release is not a published stable release")
		}
		result.Latest = id
	}
	return result, nil
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

// create sends the single create-release request. It is never retried.
func (p *publisher) create(ctx context.Context, a *inspection.Admission, token string) (string, error) {
	payload, err := json.Marshal(map[string]any{"tag_name": a.Tag, "target_commitish": a.SourceSHA, "name": a.Tag,
		"body": Receipt(a), "draft": false, "prerelease": false, "generate_release_notes": false,
		// The endpoint's make_latest is a string enum; anything else defaults to "true".
		"make_latest": "false"})
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
		return "", errors.New("publication request outcome is unknown; do not retry, run recovery again to reconcile")
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(response.Body, maxResponse+1))
	if err != nil || len(raw) > maxResponse {
		return "", errors.New("publication response is incomplete; run recovery again to reconcile")
	}
	if response.StatusCode != http.StatusCreated {
		return "", fmt.Errorf("publication was refused with status %d", response.StatusCode)
	}
	mediaType, _, err := mime.ParseMediaType(response.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" && mediaType != "application/vnd.github+json" {
		return "", errors.New("publication response is not JSON; run recovery again to reconcile")
	}
	value, err := inspection.StrictJSON(raw)
	release := object(value)
	id, ok := positiveID(release["id"])
	if err != nil || !ok || release["tag_name"] != a.Tag || release["draft"] != false || release["prerelease"] != false {
		return "", errors.New("publication response does not describe the requested release; run recovery again to reconcile")
	}
	return id, nil
}

// verify re-reads the release, the admitted identity and the latest anchor independently.
func (p *publisher) verify(ctx context.Context, args []string, a *inspection.Admission, token, id string, before inventory) error {
	value, present, err := p.reader.Get(ctx, "/repos/"+a.Repository+"/releases/tags/"+a.Tag, token, true)
	if err != nil {
		return fmt.Errorf("publication readback: %w", err)
	}
	release := object(value)
	readID, _ := positiveID(release["id"])
	commitish := text(release["target_commitish"])
	if !present || readID != id || release["tag_name"] != a.Tag || release["draft"] != false ||
		release["prerelease"] != false || release["body"] != Receipt(a) ||
		commitish != a.SourceSHA && commitish != a.DefaultBranch {
		return errors.New("publication readback does not match the requested release")
	}
	after, err := p.reader.Admit(ctx, args, token)
	if err != nil {
		return fmt.Errorf("post-publication admission: %w", err)
	}
	if !a.SameIdentity(after) || !after.Published {
		return errors.New("post-publication observation does not match the admitted tag and source")
	}
	value, present, err = p.reader.Get(ctx, "/repos/"+a.Repository+"/releases/latest", token, true)
	if err != nil {
		return fmt.Errorf("latest release readback: %w", err)
	}
	latest := ""
	if present {
		latest, _ = positiveID(object(value)["id"])
	}
	if latest != before.Latest {
		return errors.New("the latest release changed during publication")
	}
	return nil
}

func report(out io.Writer, a *inspection.Admission, result, id string, posts int) error {
	raw, err := json.Marshal(map[string]any{"result": result, "repository": a.Repository, "tag": a.Tag,
		"source_sha": a.SourceSHA, "run_id": a.RunID, "run_attempt": a.RunAttempt, "producer_ref": a.ProducerRef,
		"release_id": id, "publication_requests": posts, "release_notes": "not-reconstructed", "latest_release": "unchanged"})
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
		return report(out, admission, "already-published", "", 0)
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
		return report(out, again, "already-published", "", 0)
	}
	id, err := p.create(ctx, again, token)
	if err != nil {
		return err
	}
	if err := p.verify(ctx, args, again, token, id, before); err != nil {
		return err
	}
	return report(out, again, "published", id, 1)
}

// Run publishes against the fixed production API with the supplied writer credential.
func Run(args []string, token string, out io.Writer) error {
	return run(args, token, out, newPublisher(nil, apiURL))
}
