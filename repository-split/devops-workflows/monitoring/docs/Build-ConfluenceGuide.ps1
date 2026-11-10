param([string]$OutputDirectory = $PSScriptRoot)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$source = Join-Path $PSScriptRoot 'NORTHWEST-CICD-HOW-TO.md'
if (-not (Test-Path -LiteralPath $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory | Out-Null }
$diagram = Join-Path $OutputDirectory 'northwest-cicd-architecture.png'
$document = Join-Path $OutputDirectory 'Northwest-CICD-Setup-and-Operations.docx'

# Draw the architecture locally so the picture can also be attached to Confluence.
$bitmap = New-Object System.Drawing.Bitmap(1600, 1250)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.Clear([System.Drawing.Color]::White)
$graphics.SmoothingMode = 'AntiAlias'
$graphics.TextRenderingHint = 'AntiAliasGridFit'
$titleFont = New-Object System.Drawing.Font('Segoe UI', 29, [System.Drawing.FontStyle]::Bold)
$headingFont = New-Object System.Drawing.Font('Segoe UI', 21, [System.Drawing.FontStyle]::Bold)
$bodyFont = New-Object System.Drawing.Font('Segoe UI', 19)
$ink = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml('#16324f'))
$pen = New-Object System.Drawing.Pen([System.Drawing.ColorTranslator]::FromHtml('#49769a'), 3)
$pen.EndCap = 'ArrowAnchor'
function Box($x, $y, $width, $height, $heading, $body, $color) {
    $brush = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml($color))
    $graphics.FillRectangle($brush, $x, $y, $width, $height)
    $graphics.DrawString($heading, $headingFont, $ink, [System.Drawing.RectangleF]::new($x+18,$y+14,$width-36,45))
    $graphics.DrawString($body, $bodyFont, $ink, [System.Drawing.RectangleF]::new($x+18,$y+64,$width-36,$height-70))
    $brush.Dispose()
}
function Arrow($x1,$y1,$x2,$y2) { $graphics.DrawLine($pen,$x1,$y1,$x2,$y2) }
$graphics.DrawString('Northwest CI/CD monitoring - how the data moves', $titleFont, $ink, 35, 24)
$graphics.DrawString('Existing collection is verified. Release evidence and inventory still need live validation.', $bodyFont, $ink, 35, 82)
Box 35 145 470 215 '1. Application repository' "Workflow completes in GitHub.`nCaller starts the shared collector.`nSmall repo config selects profiles." '#eaf3fa'
Box 565 145 470 215 '2. devops-workflows' "Shared workflows and scripts.`nGitHub API returns run, job and step results. Central stage profiles add labels." '#eaf3fa'
Box 1095 145 470 215 'Authentication' "GitHub OIDC trusts the caller repo + environment.`nManaged identity has permission on each publishing DCR." '#edf5ed'
Arrow 505 245 565 245
Arrow 1095 245 1035 245
Box 35 420 470 210 'Release evidence - next' "Pipeline reports target, version, rollback and check results.`nSmoke tests run in the pipeline." '#fff2da'
Box 565 420 470 210 'Inventory - next' "Read configured Container Apps.`nRecord revisions, images and traffic.`nVM / Kubernetes: evidence reports; no live inventory adapter yet." '#fff2da'
Box 1095 420 470 210 'Collector health' "Scheduled GitHub checks.`nHeartbeat and collector results.`n1 PM and 5 PM Eastern in the configured workflow." '#eaf3fa'
$graphics.DrawString('Collector, health, release and inventory scripts send JSON over HTTPS to Azure', $bodyFont, $ink, 35, 665)
Box 35 720 470 170 '3. DCE' "Logs ingestion endpoint.`nReceives the records sent by the collector." '#edf5ed'
Box 565 720 470 170 '4. DCRs' "Declare input schemas, transform records and route each stream into its table." '#edf5ed'
Box 1095 720 470 170 '5. Log Analytics' "Tables store workflow, execution, health, deployment, release and inventory records." '#edf5ed'
Arrow 505 805 565 805
Arrow 1035 805 1095 805
Box 35 965 1000 170 '6. Azure Monitor dashboards' "Workbooks and Dashboards with Grafana query Log Analytics.`nDevelopers see failures, durations, stages and links to GitHub.`nDORA needs reviewed production, change and incident evidence." '#eaf3fa'
Box 1095 965 470 170 'Alerts - pending validation' "Azure Monitor rules + action group.`nServiceNow needs a separate integration and end-to-end test." '#fff2da'
Arrow 1330 890 1330 930
Arrow 1330 930 800 930
Arrow 800 930 800 965
$graphics.DrawString('Blue: GitHub / dashboard flow     Green: Azure access and storage     Amber: additional setup and validation', $bodyFont, $ink, 35, 1170)
$bitmap.Save($diagram, [System.Drawing.Imaging.ImageFormat]::Png)
$graphics.Dispose(); $bitmap.Dispose(); $titleFont.Dispose(); $headingFont.Dispose(); $bodyFont.Dispose(); $ink.Dispose(); $pen.Dispose()

function XmlText([string]$text) { [System.Security.SecurityElement]::Escape($text) }
function Plain([string]$text) {
    $text = $text -replace '\[([^\]]+)\]\(([^)]+)\)', '$1 ($2)'
    $text -replace '[`*]', ''
}
function Paragraph([string]$text, [string]$style = 'Normal') {
    $escaped = XmlText (Plain $text)
    '<w:p><w:pPr><w:pStyle w:val="'+$style+'"/></w:pPr><w:r><w:t xml:space="preserve">'+$escaped+'</w:t></w:r></w:p>'
}
$parts = New-Object 'System.Collections.Generic.List[string]'
$lines = [System.IO.File]::ReadAllLines($source)
$inCode = $false
for ($index=0; $index -lt $lines.Length; $index++) {
    $line = $lines[$index]
    if ($line.StartsWith('```')) { $inCode = -not $inCode; continue }
    if ($inCode) {
        $parts.Add('<w:p><w:pPr><w:pStyle w:val="Code"/></w:pPr><w:r><w:t xml:space="preserve">'+(XmlText $line)+'</w:t></w:r></w:p>')
        continue
    }
    if ($line -match '^!\[') {
        $parts.Add(@'
<w:p><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="5943600" cy="4643438"/><wp:docPr id="1" name="CI/CD architecture" descr="GitHub collector, identity, Azure ingestion, tables and dashboards"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="architecture.png"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="rIdImage"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="5943600" cy="4643438"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
'@)
        continue
    }
    if ($line.StartsWith('|')) {
        $rows = New-Object 'System.Collections.Generic.List[object]'
        while ($index -lt $lines.Length -and $lines[$index].StartsWith('|')) {
            if ($lines[$index] -notmatch '^\|[\s:|\-]+$') { $rows.Add($lines[$index].Trim('|').Split('|')) }
            $index++
        }
        $index--
        $columnCount = $rows[0].Count
        $cellWidth = [int](9360 / $columnCount)
        $table = '<w:tbl><w:tblPr><w:tblStyle w:val="GuideTable"/><w:tblW w:w="9360" w:type="dxa"/><w:tblLayout w:type="fixed"/></w:tblPr><w:tblGrid>'
        for ($c=0; $c -lt $columnCount; $c++) { $table += '<w:gridCol w:w="'+$cellWidth+'"/>' }
        $table += '</w:tblGrid>'
        for ($row=0; $row -lt $rows.Count; $row++) {
            $table += '<w:tr><w:trPr><w:cantSplit/>'
            if ($row -eq 0) { $table += '<w:tblHeader/>' }
            $table += '</w:trPr>'
            foreach ($cell in $rows[$row]) {
                $table += '<w:tc><w:tcPr><w:tcW w:w="'+$cellWidth+'" w:type="dxa"/>'
                if ($row -eq 0) { $table += '<w:shd w:fill="EAF3FA"/>' }
                $table += '</w:tcPr>'+(Paragraph $cell.Trim() 'TableText')+'</w:tc>'
            }
            $table += '</w:tr>'
        }
        $parts.Add($table+'</w:tbl>'); $parts.Add((Paragraph '')); continue
    }
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    if ($line -match '^(#{1,3}) (.+)$') {
        $level = $Matches[1].Length
        $style = @('Title','Heading1','Heading2')[$level-1]
        $parts.Add((Paragraph $Matches[2] $style))
    } else { $parts.Add((Paragraph $line)) }
}
$body = $parts -join "`n"
$documentXml = @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>$body<w:sectPr><w:footerReference w:type="default" r:id="rIdFooter"/><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1080" w:right="1440" w:bottom="1080" w:left="1440" w:header="360" w:footer="540"/></w:sectPr></w:body></w:document>
"@
$styles = @'
<?xml version="1.0" encoding="UTF-8"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri"/><w:sz w:val="22"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="120"/><w:widowControl/></w:pPr></w:pPrDefault></w:docDefaults>
<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
<w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:after="240"/></w:pPr><w:rPr><w:b/><w:color w:val="16324F"/><w:sz w:val="36"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="300" w:after="160"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:color w:val="16324F"/><w:sz w:val="29"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="220" w:after="120"/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:sz w:val="24"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="TableText"><w:name w:val="Table text"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="60"/></w:pPr><w:rPr><w:sz w:val="18"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="0"/><w:shd w:fill="F3F5F7"/></w:pPr><w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas"/><w:sz w:val="17"/></w:rPr></w:style>
<w:style w:type="table" w:styleId="GuideTable"><w:name w:val="Guide table"/><w:tblPr><w:tblBorders><w:top w:val="single" w:sz="4" w:color="CCD6DD"/><w:left w:val="single" w:sz="4" w:color="CCD6DD"/><w:bottom w:val="single" w:sz="4" w:color="CCD6DD"/><w:right w:val="single" w:sz="4" w:color="CCD6DD"/><w:insideH w:val="single" w:sz="4" w:color="CCD6DD"/><w:insideV w:val="single" w:sz="4" w:color="CCD6DD"/></w:tblBorders><w:tblCellMar><w:top w:w="90" w:type="dxa"/><w:left w:w="100" w:type="dxa"/><w:bottom w:w="90" w:type="dxa"/><w:right w:w="100" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>
</w:styles>
'@
$contentTypes = '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/></Types>'
$rootRels = '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>'
$docRels = '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/><Relationship Id="rIdImage" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/architecture.png"/><Relationship Id="rIdFooter" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/></Relationships>'
$footer = '<w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p><w:pPr><w:jc w:val="right"/></w:pPr><w:r><w:t>Northwest CI/CD monitoring | </w:t></w:r><w:fldSimple w:instr="PAGE"/></w:p></w:ftr>'
$stream = [System.IO.File]::Open($document, [System.IO.FileMode]::Create)
$zip = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    $xmlParts = @{ '[Content_Types].xml'=$contentTypes; '_rels/.rels'=$rootRels; 'word/document.xml'=$documentXml; 'word/styles.xml'=$styles; 'word/_rels/document.xml.rels'=$docRels; 'word/footer1.xml'=$footer }
    foreach ($name in $xmlParts.Keys) {
        [xml]$validXml = $xmlParts[$name]
        $entry = $zip.CreateEntry($name)
        $writer = New-Object System.IO.StreamWriter($entry.Open(), [System.Text.UTF8Encoding]::new($false))
        try { $writer.Write($xmlParts[$name]) } finally { $writer.Dispose() }
    }
    $imageEntry = $zip.CreateEntry('word/media/architecture.png')
    $imageStream = $imageEntry.Open()
    try { $imageBytes = [System.IO.File]::ReadAllBytes($diagram); $imageStream.Write($imageBytes,0,$imageBytes.Length) } finally { $imageStream.Dispose() }
} finally { $zip.Dispose(); $stream.Dispose() }
Write-Output "Created $document"
Write-Output "Created $diagram"
