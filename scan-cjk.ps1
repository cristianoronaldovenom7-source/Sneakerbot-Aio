$root = 'C:\Users\User\Documents\Codex\2026-08-13\h\work\sneakerbot-src'
$files = Get-ChildItem -Path $root -Recurse -File -Include *.md,*.js,*.mjs,*.json,*.sh,*.yml,*.yaml,*.html,*.css,*.ps1 |
  Where-Object { $_.FullName -notmatch 'node_modules|package-lock|\\\.local\\' }

# Two bugs used to make this always print nothing:
#   1. '[\u4e00-\u9fff]' inside a SINGLE-quoted string is not an escape — .NET
#      regex never saw the range. Build it from codepoints instead.
#   2. Get-Content -Raw with no -Encoding decodes UTF-8 as ANSI under PS 5.1, so
#      CJK had already become mojibake before the match ran.
$cjkPattern = '[' + [char]0x4e00 + '-' + [char]0x9fff + ']'

$out = foreach ($f in $files) {
  $c = Get-Content $f.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
  if ($c -and $c -match $cjkPattern) {
    $n = ([regex]::Matches($c, $cjkPattern)).Count
    [pscustomobject]@{ Count = $n; Path = $f.FullName.Replace($root + '\', '') }
  }
}
$out | Sort-Object -Property Count -Descending | Format-Table -AutoSize
'--- total files: ' + @($out).Count
