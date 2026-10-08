# Shared request/readback schema for fields that change which workflows a policy targets.
def selector_strings:
  type == "array" and all(.[]; type == "string" and length > 0);

def property_members:
  type == "array" and all(.[];
    type == "object"
    and (keys - ["name", "property_values", "source"] | length) == 0
    and (.name | type == "string" and length > 0)
    and (.property_values | type == "array" and length > 0 and all(.[]; type == "string"))
    and (if has("source") then (.source == "custom" or .source == "system") else true end));

def valid_workflow_selectors:
  type == "object"
  and (keys - ["repository_name", "repository_id", "repository_property", "workflow_path"] | length) == 0
  and ([keys[] | select(. != "workflow_path")] | length) == 1
  and all(to_entries[];
    .key as $key | .value |
    type == "object" and
    if $key == "repository_name" then
      (keys - ["include", "exclude", "protected"] | length) == 0
      and (.include | selector_strings)
      and (if has("exclude") then (.exclude | selector_strings) else true end)
      and (if has("protected") then (.protected | type == "boolean") else true end)
    elif $key == "repository_id" then
      keys == ["repository_ids"]
      and (.repository_ids | type == "array" and all(.[]; type == "number" and floor == .))
    elif $key == "repository_property" then
      (keys - ["include", "exclude"] | length) == 0
      and (.include | property_members)
      and (if has("exclude") then (.exclude | property_members) else true end)
    else
      keys == ["exclude", "include"]
      and (.include | selector_strings) and (.exclude | selector_strings)
    end);

def normalize_workflow_selectors:
  def members:
    map({name, source: (.source // "custom"), property_values: (.property_values | sort)}) | sort;
  with_entries(
    if .key == "repository_id" then .value = {repository_ids: (.value.repository_ids | sort)}
    elif .key == "repository_property" then
      .value = {include: (.value.include | members), exclude: (.value.exclude // [] | members)}
    elif .key == "repository_name" then
      .value |= ({include: (.include | sort), exclude: (.exclude // [] | sort)}
        + if has("protected") then {protected} else {} end)
    else .value = {include: (.value.include | sort), exclude: (.value.exclude | sort)} end);
