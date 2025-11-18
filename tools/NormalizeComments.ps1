Param(
    [string]$Root = (Get-Location).Path,
    [string[]]$Extensions = @('*.c','*.cc','*.cpp','*.cxx','*.h','*.hh','*.hpp','*.hxx','*.inl','*.rc')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-TextWithBestGuessEncoding {
    Param([byte[]]$Bytes)

    # Detect BOMs
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return [System.Text.Encoding]::UTF8.GetString($Bytes, 3, $Bytes.Length - 3)
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        return [System.Text.Encoding]::Unicode.GetString($Bytes, 2, $Bytes.Length - 2) # UTF-16 LE
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) {
        return [System.Text.Encoding]::BigEndianUnicode.GetString($Bytes, 2, $Bytes.Length - 2)
    }

    # No BOM: assume legacy Windows-1252 for this codebase
    $enc = [System.Text.Encoding]::GetEncoding(1252)
    return $enc.GetString($Bytes)
}

function Convert-CommentCharToAscii {
    Param([char]$ch)

    # Common mappings
    switch ([int][char]$ch) {
        0x00A9 { return '(c)' }      # ©
        0x00AE { return '(R)' }      # ®
        0x2122 { return '(TM)' }     # ™
        0x2013 { return '-' }        # – en dash
        0x2014 { return '-' }        # — em dash
        0x2026 { return '...' }      # … ellipsis
        0x2018 { return "'" }       # ‘
        0x2019 { return "'" }       # ’
        0x201C { return '"' }       # “
        0x201D { return '"' }       # ”
        0x00AB { return '"' }       # «
        0x00BB { return '"' }       # »
        0x00B7 { return '*' }        # ·
        0x00A0 { return ' ' }        # non-breaking space
        default {
            if ([int][char]$ch -le 0x7F) { return [string]$ch }
            # Unmapped non-ASCII: replace with '?' to keep visible marker
            return '?'
        }
    }
}

function Normalize-CommentsText {
    Param([string]$text)

    $sb = New-Object System.Text.StringBuilder

    $inLineComment = $false
    $inBlockComment = $false
    $inString = $false
    $inChar = $false
    $escape = $false

    $len = $text.Length
    for ($i = 0; $i -lt $len; $i++) {
        $ch = $text[$i]
        $next = if ($i + 1 -lt $len) { $text[$i+1] } else { [char]0 }

        if ($inLineComment) {
            if ($ch -eq "`n") { $inLineComment = $false; [void]$sb.Append($ch); continue }
            # Replace character inside line comment
            $rep = Convert-CommentCharToAscii -ch $ch
            [void]$sb.Append($rep)
            continue
        }
        if ($inBlockComment) {
            # Check for end of block comment
            if ($ch -eq '*' -and $next -eq '/') {
                [void]$sb.Append('*')
                [void]$sb.Append('/')
                $i++
                $inBlockComment = $false
                continue
            }
            $rep = Convert-CommentCharToAscii -ch $ch
            [void]$sb.Append($rep)
            continue
        }

        if ($inString) {
            [void]$sb.Append($ch)
            if ($escape) { $escape = $false; continue }
            if ($ch -eq '\\') { $escape = $true; continue }
            if ($ch -eq '"') { $inString = $false }
            continue
        }
        if ($inChar) {
            [void]$sb.Append($ch)
            if ($escape) { $escape = $false; continue }
            if ($ch -eq '\\') { $escape = $true; continue }
            if ($ch -eq "'") { $inChar = $false }
            continue
        }

        # Not in any construct: detect comment/string/char starts
        if ($ch -eq '/' -and $next -eq '/') {
            [void]$sb.Append('/')
            [void]$sb.Append('/')
            $i++
            $inLineComment = $true
            continue
        }
        if ($ch -eq '/' -and $next -eq '*') {
            [void]$sb.Append('/')
            [void]$sb.Append('*')
            $i++
            $inBlockComment = $true
            continue
        }
        if ($ch -eq '"') { $inString = $true; [void]$sb.Append($ch); continue }
        if ($ch -eq "'") { $inChar = $true; [void]$sb.Append($ch); continue }

        [void]$sb.Append($ch)
    }

    return $sb.ToString()
}

function Save-AsUtf8Bom {
    Param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $utf8bom = New-Object System.Text.UTF8Encoding($true)
    $bytes = $utf8bom.GetBytes($Text)
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

function Process-File {
    Param([string]$Path)
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $text = Get-TextWithBestGuessEncoding -Bytes $bytes

        $newText = Normalize-CommentsText -text $text
        if ($newText -ne $text) {
            Save-AsUtf8Bom -Path $Path -Text $newText
            return $true
        }
        return $false
    }
    catch {
        Write-Warning ("Failed to process {0}: {1}" -f $Path, $_)
        return $false
    }
}

$total = 0
$changed = 0

foreach ($ext in $Extensions) {
    Get-ChildItem -Path $Root -Recurse -Include $ext -File | ForEach-Object {
        $total++
        if (Process-File -Path $_.FullName) { $changed++ }
    }
}

Write-Host "Processed files: $total"
Write-Host "Changed files:   $changed"
