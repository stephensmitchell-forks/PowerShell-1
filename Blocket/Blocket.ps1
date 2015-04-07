Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-BlocketSearchHits([string]$Query, [string]$Category, [string]$Area) {
    if ([string]::IsNullOrEmpty($Category)) {
        $Category = 0 # 2040 is furniture
    }
    if ([string]::IsNullOrEmpty($Area)) {
        $Area = "orebro"
    }
    $baseUri = "http://www.blocket.se/$($Area)?q=$($query.Trim())&cg=$Category&w=1&st=s&c=&ca=8&is=1&l=0&md=th"
    return Read-Html $baseUri | Select-HtmlByClass "item_link" | Get-HtmlAttribute href
}

function Get-SearchHitContent([string]$Uri) {
    $html = Read-Html $Uri
    $images = $html | Select-HtmlLink | Get-HtmlAttribute href | where { $_ -match "jpg$" }
    if ($images -eq $null) { # If there is only one image in the ad, no thumbnail links are shown
        $images = $html | Select-HtmlById main_image | Get-HtmlAttribute src
    }
    $title = $html | Select-HtmlByXPath "//h2" | select -First 1 | %{ $_.innerText.Trim() }
    $text = $html | Select-HtmlByClass body | foreach { 
        $_.innerHtml.Replace("<!-- Info page -->","").Trim()
    }
    $price = $html | Select-HtmlById vi_price | foreach { $_.innerText.Trim() }
    
    return New-Object PSObject -Property @{ 'images'=$images; 'title'=$title; 'text'=$text; 'price'="$price"; 'uri'=$Uri }
}

function Test-Hit($Uri) {
    @(Get-ChildItem sqlite:\BlocketSearchHit -Filter "uri='$Uri'").Length -gt 0
}

function Test-Query($Query) {
    @(Get-ChildItem sqlite:\BlocketSearchQuery -Filter "text='$Query'").Length -gt 0
}

function Add-Hit($Uri) {
    New-Item sqlite:\BlocketSearchHit -uri $Uri | Out-Null
}

function Add-Query($Query) {
    New-Item sqlite:\BlocketSearchQuery -text $Query | Out-Null
}

function Format-Body {
    param(
        [Parameter(Mandatory=$True, ValueFromPipeline=$True, ValueFromPipelineByPropertyName)]
        [string[]]$Images,
        [Parameter(Mandatory=$True, ValueFromPipeline=$True, ValueFromPipelineByPropertyName)]
        [string]$Title,
        [Parameter(Mandatory=$True, ValueFromPipeline=$True, ValueFromPipelineByPropertyName)]
        [string]$Text,
        [Parameter(ValueFromPipeline=$True, ValueFromPipelineByPropertyName)]
        [string]$Price,
        [Parameter(Mandatory=$True, ValueFromPipeline=$True, ValueFromPipelineByPropertyName)]
        [string]$Uri
    )
    Process {
        $imageTagsArray = $Images | %{ "<img src=""$_""/>" }
        $imageTags = [string]::Join("`r`n", $imageTagsArray)
        $PriceTags = $null
        if (-not [string]::IsNullOrEmpty($Price)) {
            $PriceTags = "<h3>Pris</h3><p>$Price</p>"
        }
        return @"
<h2>$Title</h2>
<p>$Text</p>
$PriceTags
<p>$imageTags</p>
<p><a href="$Uri">Se annonsen p� Blocket</a></p>
"@
    }
}

# It is a good thing not to load queries from db since one can rely on different schedules for differnt queries
function Send-BlocketSearchHitsMail {
    [CmdletBinding()]    param(
        [Parameter(Mandatory=$True, ValueFromPipeline=$True, ValueFromPipelineByPropertyName)]
        [string]$Query,
        [string]$Category,
        [string]$Area,
        [Parameter(Mandatory=$True)]
        [string[]]$EmailTo,
        [Parameter(Mandatory=$True)]
        [string]$EmailFrom
    )
    Process {
        $hits = Get-BlocketSearchHits $Query
        # Mute emails the first run
        if (-not (Test-Query $Query)) {
            Add-Query $Query
            $hits | %{ Add-Hit $_ }
            Write-Output "Added $(@($hits).Length) items to recorded search hits. No mails are sent out this time!"
            return
        }
        $newHits = @($hits | where { -not (Test-Hit $_) })
        if ($newHits.Length -eq 0) {
            return
        }
        Write-Log "Found new search hits"
        # Send emails for new hits
        $newHits | foreach {
            $hit = $_
            $content = Get-SearchHitContent $hit
            $body = $content | Format-Body
            $subject = "Blocket: $($content.Title) - $($content.Price)"
            Send-Gmail -EmailFrom $EmailFrom -EmailTo $EmailTo -Subject $subject -Body $body -Html
            Write-Log "Email with subject '$subject' to $EmailTo"
            Add-Hit $hit
        } 
    }
}

function Remove-BlocketRecordedHits {    [CmdletBinding()]    param()    Remove-Item sqlite:\BlocketSearchHit\*
    Remove-Item sqlite:\BlocketSearchQuery\*
}

#Remove-BlocketData -Verbose
#Send-BlocketSearchHitsMail "*hemnes* *byr�*" "johan@classon.eu","johan2@classon.eu" "johan@classon.eu" -Verbose
#Get-BlocketSearchHits "*hemnes* *byr�*"
