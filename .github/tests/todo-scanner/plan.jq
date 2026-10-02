. as $case |
{Name,WantFailure:(.WantFailure // false),Output,ForbiddenOutput:(.ForbiddenOutput // []),
 Exchanges:([
   {Method:"GET",Path:"/github/linguist/master/lib/linguist/languages.yml",Raw:true,Status:200,Response:"Shell:\n  extensions: [\".sh\"]\n  ace_mode: sh\nGo:\n  extensions: [\".go\"]\n  ace_mode: golang\n"},
   {Method:"GET",Path:"/alstr/todo-to-issue-action/master/syntax.json",Raw:true,Status:200,Response:"[{\"language\":\"Shell\",\"markers\":[{\"type\":\"line\",\"pattern\":\"#\"}]},{\"language\":\"Go\",\"markers\":[{\"type\":\"line\",\"pattern\":\"//\"}]}]"}]
   + ($case.InitialReads // [
     {Method:"GET",Path:"/repos/offline/fixture/issues?per_page=100&page=1&state=open",Status:200,Response:($case.Existing // [] | tojson)},
     {Method:"GET",Path:"/repos/offline/fixture/milestones?per_page=100&page=1&state=open",Status:200,Response:"[]"}])
   + (if .DiffError then [
     {Method:"GET",Path:"/repos/offline/fixture/compare/fixture-base...1111111111111111111111111111111111111111",Status:503,Response:"{\"message\":\"Offline diff failure\"}"},
     {Method:"GET",Path:"/repos/offline/fixture/commits/1111111111111111111111111111111111111111",Status:503,Response:"{\"message\":\"Offline fallback failure\"}"}]
   else [
     {Method:"GET",Path:"/repos/offline/fixture/compare/fixture-base...1111111111111111111111111111111111111111",Status:200,Response:$diff}]
   end) + .Operations)}
