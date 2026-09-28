$script:RegionMappingPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'data/azure-region-eic-mapping.json'

# This file is organized in the same order as the gate's work:
# validate input, access storage, retrieve forecasts, make a decision, and respond.

# Write one consistent, searchable line to the Azure Functions information log.
function Write-GateLog {
    param(
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][string]$Message
    )

    Write-Information "[GreenOpsGate][$Step] $Message" -InformationAction Continue
}

# Request validation
# ------------------
# Turn the JSON body into a predictable object used by the rest of the script.
function ConvertFrom-GateRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$InputObject)

    # Azure Functions can deserialize JSON as either a hashtable or a PSCustomObject.
    $values = @{}
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            $values[$key.ToString().ToLowerInvariant()] = $InputObject[$key]
        }
    }
    else {
        foreach ($property in $InputObject.PSObject.Properties) {
            $values[$property.Name.ToLowerInvariant()] = $property.Value
        }
    }

    foreach ($name in @('buildid', 'projectid', 'category', 'preferredlocation', 'allowedlocations', 'allowedwaitminutes')) {
        if (-not $values.ContainsKey($name) -or [string]::IsNullOrWhiteSpace([string]$values[$name])) {
            throw [System.ArgumentException]::new("'$name' is required.")
        }
    }

    $category = $values.category.ToString().ToLowerInvariant()
    if ($category -notin @('hotfix', 'test', 'production')) {
        throw [System.ArgumentException]::new("Unknown category '$($values.category)'.")
    }

    $locationValues = if ($values.allowedlocations -is [array]) {
        $values.allowedlocations
    }
    else {
        $values.allowedlocations.ToString().Split(',')
    }
    $locations = @($locationValues | ForEach-Object { $_.ToString().Trim().ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)
    if ($locations.Count -eq 0) {
        throw [System.ArgumentException]::new('AllowedLocations must contain at least one location.')
    }

    $knownLocations = @((Get-Content $script:RegionMappingPath -Raw | ConvertFrom-Json).regions.azureRegion)
    $unknownLocations = @($locations | Where-Object { $_ -notin $knownLocations })
    if ($unknownLocations.Count -gt 0) {
        throw [System.ArgumentException]::new("Unknown Azure location(s): $($unknownLocations -join ', ').")
    }

    $preferredLocation = $values.preferredlocation.ToString().Trim().ToLowerInvariant()
    if ($preferredLocation -notin $locations) {
        throw [System.ArgumentException]::new('PreferredLocation must be included in AllowedLocations.')
    }

    $allowedWaitMinutes = 0
    if (-not [int]::TryParse($values.allowedwaitminutes.ToString(), [ref]$allowedWaitMinutes) -or $allowedWaitMinutes -lt 0) {
        throw [System.ArgumentException]::new('AllowedWaitMinutes must be a non-negative integer.')
    }

    [pscustomobject]@{
        BuildId           = [string]$values.buildid
        ProjectId         = [string]$values.projectid
        RepositoryId      = if ($values.ContainsKey('repositoryid')) { [string]$values.repositoryid } else { '' }
        Category          = $category
        PreferredLocation = $preferredLocation
        AllowedLocations  = $locations
        AllowedWaitMinutes = $allowedWaitMinutes
    }
}
# Azure Table Storage
# -------------------
# Decisions are addressed by project, build, and deployment category. These
# functions contain all Table REST details so the orchestration stays readable.
function Get-TableEntityUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TableUri,
        [Parameter(Mandatory)][string]$PartitionKey,
        [Parameter(Mandatory)][string]$RowKey
    )

    # A single quote is escaped by doubling it in an OData key expression.
    $safePartitionKey = $PartitionKey.Replace("'", "''")
    $safeRowKey = $RowKey.Replace("'", "''")
    "$TableUri(PartitionKey='$safePartitionKey',RowKey='$safeRowKey')"
}

function Get-StoredDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TableUri,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][string]$PartitionKey,
        [Parameter(Mandatory)][string]$RowKey
    )

    $uri = Get-TableEntityUri -TableUri $TableUri -PartitionKey $PartitionKey -RowKey $RowKey
    try {
        Invoke-RestMethod -Method Get -Uri $uri -Headers $Headers -ErrorAction Stop
    }
    catch {
        # A missing entity is normal on the first request for a build.
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
            return $null
        }
        throw
    }
}
function Save-Decision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TableUri,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][pscustomobject]$Entity
    )

    # Convert the PowerShell object to the flat JSON shape expected by Tables.
    $properties = [ordered]@{
        PartitionKey = $Entity.PartitionKey
        RowKey = $Entity.RowKey
    }
    foreach ($property in $Entity.PSObject.Properties) {
        if ($property.Name -notin @('PartitionKey', 'RowKey') -and $null -ne $property.Value) {
            $properties[$property.Name] = $property.Value
        }
    }

    $uri = Get-TableEntityUri -TableUri $TableUri -PartitionKey $Entity.PartitionKey -RowKey $Entity.RowKey

    # PUT without If-Match means "insert or replace": it works for both a new
    # decision and a later poll that updates its status.
    Invoke-RestMethod -Method Put -Uri $uri -Headers $Headers -ContentType 'application/json' -Body ($properties | ConvertTo-Json -Depth 10) -ErrorAction Stop | Out-Null
}

# Forecast data
# -------------
# Azure regions are mapped to ENTSO-E bidding zones through the checked-in JSON.
# Return the bidding zone that belongs to one Azure region.
function Resolve-EntsoeArea {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Location)

    $region = (Get-Content $script:RegionMappingPath -Raw | ConvertFrom-Json).regions |
        Where-Object azureRegion -eq $Location.ToLowerInvariant()
    if (-not $region) {
        throw [System.ArgumentException]::new("No ENTSO-E mapping exists for '$Location'.")
    }
    $region
}

# Expand ENTSO-E's compact period/position format into timestamped data points.
function ConvertFrom-EntsoeSeries {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Document)

    $series = @($Document.GL_MarketDocument.TimeSeries)
    if ($series.Count -eq 0 -or $null -eq $series[0]) {
        $reason = [string]$Document.Acknowledgement_MarketDocument.Reason.text
        if ([string]::IsNullOrWhiteSpace($reason)) {
            $reason = 'The response did not contain forecast time series.'
        }
        throw "ENTSO-E rejected the request: $reason"
    }

    # ENTSO-E points use a 1-based position relative to the period start.
    foreach ($timeSeries in $series) {
        foreach ($period in @($timeSeries.Period)) {
            $periodStart = [datetimeoffset]::Parse([string]$period.timeInterval.start).UtcDateTime
            $resolution = [System.Xml.XmlConvert]::ToTimeSpan([string]$period.resolution)
            foreach ($point in @($period.Point)) {
                $startUtc = $periodStart.AddTicks($resolution.Ticks * ([int]$point.position - 1))
                [pscustomobject]@{
                    StartUtc = $startUtc
                    EndUtc   = $startUtc.Add($resolution)
                    Quantity = [double]$point.quantity
                }
            }
        }
    }
}

# Retrieve total-generation and wind/solar forecasts for every allowed region.
function Get-RegionForecast {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Locations,
        [Parameter(Mandatory)][datetime]$StartUtc,
        [Parameter(Mandatory)][int]$WaitMinutes,
        [string]$EntsoeToken = $env:ENTSOE_TOKEN
    )

    if ([string]::IsNullOrWhiteSpace($EntsoeToken)) {
        throw 'ENTSOE_TOKEN is not configured.'
    }

    $start = $StartUtc.ToUniversalTime()
    $deadline = $start.AddMinutes($WaitMinutes)

    # Include the active forecast interval and one hour beyond the wait boundary.
    $queryStart = [datetime]::new($start.Year, $start.Month, $start.Day, $start.Hour, 0, 0, [DateTimeKind]::Utc)
    $queryEnd = $deadline.AddHours(1)
    $queryEnd = [datetime]::new($queryEnd.Year, $queryEnd.Month, $queryEnd.Day, $queryEnd.Hour, 0, 0, [DateTimeKind]::Utc)
    if ($queryEnd -le $queryStart) {
        $queryEnd = $queryStart.AddHours(1)
    }

    $areas = foreach ($location in $Locations) {
        $area = Resolve-EntsoeArea -Location $location
        [pscustomobject]@{ Location = $location; EicCode = $area.eicCode }
    }

    # Multiple Azure regions can map to one bidding zone, so query each EIC code once.
    foreach ($areaGroup in $areas | Group-Object EicCode) {
        $eicCode = $areaGroup.Name
        $mappedLocations = $areaGroup.Group.Location -join ', '
        Write-GateLog -Step 'Forecast' -Message "Requesting ENTSO-E forecasts for $mappedLocations using bidding zone $eicCode."
        $commonQuery = "processType=A01&in_Domain=$([uri]::EscapeDataString($eicCode))&periodStart=$($queryStart.ToString('yyyyMMddHHmm'))&periodEnd=$($queryEnd.ToString('yyyyMMddHHmm'))&securityToken=$([uri]::EscapeDataString($EntsoeToken))"
        $totalDocument = Invoke-RestMethod -Uri "https://web-api.tp.entsoe.eu/api?documentType=A71&$commonQuery" -ErrorAction Stop
        $greenDocument = Invoke-RestMethod -Uri "https://web-api.tp.entsoe.eu/api?documentType=A69&$commonQuery" -ErrorAction Stop
        $totalPoints = @(ConvertFrom-EntsoeSeries -Document $totalDocument)
        $greenPoints = @(ConvertFrom-EntsoeSeries -Document $greenDocument)
        Write-GateLog -Step 'Forecast' -Message "Received $($totalPoints.Count) total-generation and $($greenPoints.Count) wind/solar forecast point(s) for bidding zone $eicCode."

        $totalIntervals = $totalPoints | Group-Object { "$($_.StartUtc.Ticks):$($_.EndUtc.Ticks)" }
        foreach ($interval in $totalIntervals) {
            $periodStart = $interval.Group[0].StartUtc
            $periodEnd = $interval.Group[0].EndUtc
            if ($periodEnd -le $start -or $periodStart -gt $deadline) {
                continue
            }

            $sampleTime = if ($periodStart -lt $start) { $start } else { $periodStart }
            $total = ($interval.Group | Measure-Object Quantity -Sum).Sum
            $green = ($greenPoints | Where-Object { $_.StartUtc -le $sampleTime -and $_.EndUtc -gt $sampleTime } | Measure-Object Quantity -Sum).Sum

            # A71 is total generation; A69 is wind and solar only. The remainder is
            # a scheduling proxy, not fossil generation or carbon intensity.
            $residualGeneration = [math]::Max(0, [double]$total - [double]$green)

            foreach ($area in $areaGroup.Group) {
                [pscustomobject]@{
                    Location = $area.Location
                    AtUtc = $sampleTime
                    PeriodEndUtc = $periodEnd
                    MetricName = 'ResidualGenerationForecast'
                    MetricValue = [math]::Round($residualGeneration, 3)
                    MetricUnit = 'MW'
                    DataSource = 'ENTSO-E A69/A71 day-ahead forecast'
                }
            }
        }
    }
}

# Decision logic
# --------------
# A stored decision is reused on every poll. A new decision compares all
# eligible forecast points and selects the lowest residual-generation value.
function Get-DeploymentDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Request,
        [datetime]$NowUtc = [datetime]::UtcNow,
        [pscustomobject]$ExistingDecision
    )

    $now = $NowUtc.ToUniversalTime()

    # Reuse the first calculation while Azure DevOps polls the synchronous check.
    if ($ExistingDecision) {
        Write-GateLog -Step 'Decision' -Message "Reusing stored decision for location $($ExistingDecision.SelectedLocation), not before $($ExistingDecision.NotBeforeUtc)."
        if ($ExistingDecision.Category -ne $Request.Category -or
            $ExistingDecision.PreferredLocation -ne $Request.PreferredLocation -or
            $ExistingDecision.AllowedLocations -ne ($Request.AllowedLocations -join ',') -or
            [int]$ExistingDecision.AllowedWaitMinutes -ne $Request.AllowedWaitMinutes) {
            throw [System.ArgumentException]::new('Existing decision input conflicts with the current request.')
        }

        $ExistingDecision.EvaluationCount = [int]$ExistingDecision.EvaluationCount + 1
        if ($ExistingDecision.PSObject.Properties.Name -contains 'LastEvaluatedUtc') {
            $ExistingDecision.LastEvaluatedUtc = $now.ToString('o')
        }
        else {
            $ExistingDecision | Add-Member -NotePropertyName LastEvaluatedUtc -NotePropertyValue $now.ToString('o')
        }
        $notBefore = ([datetime]$ExistingDecision.NotBeforeUtc).ToUniversalTime()
        $validUntil = ([datetime]$ExistingDecision.ValidUntilUtc).ToUniversalTime()

        if ($now -gt $validUntil) {
            $ExistingDecision.DecisionStatus = 'Expired'
            $status = 'error'
        }
        elseif ($now -lt $notBefore) {
            $ExistingDecision.DecisionStatus = 'Waiting'
            $status = 'wait'
        }
        else {
            $ExistingDecision.DecisionStatus = 'Approved'
            if ($ExistingDecision.PSObject.Properties.Name -notcontains 'ApprovedAtUtc') {
                $ExistingDecision | Add-Member -NotePropertyName ApprovedAtUtc -NotePropertyValue $now.ToString('o')
            }
            elseif ([string]::IsNullOrWhiteSpace([string]$ExistingDecision.ApprovedAtUtc)) {
                $ExistingDecision.ApprovedAtUtc = $now.ToString('o')
            }
            $status = 'proceed'
        }

        Write-GateLog -Step 'Decision' -Message "Stored decision evaluated as '$status' at $($now.ToString('o'))."

        if ($ExistingDecision.PSObject.Properties.Name -contains 'Status') {
            $ExistingDecision.Status = $status
        }
        else {
            $ExistingDecision | Add-Member -NotePropertyName Status -NotePropertyValue $status
        }
        return $ExistingDecision
    }

    Write-GateLog -Step 'Forecast' -Message "Retrieving ENTSO-E forecast candidates for $($Request.AllowedLocations -join ', ') over the next $($Request.AllowedWaitMinutes) minute(s)."
    $candidates = @(Get-RegionForecast -Locations $Request.AllowedLocations -StartUtc $now -WaitMinutes $Request.AllowedWaitMinutes)
    if ($candidates.Count -eq 0) {
        throw 'The forecast provider returned no eligible results.'
    }

    Write-GateLog -Step 'Forecast' -Message "Evaluating $($candidates.Count) forecast candidate(s)."
    foreach ($location in $Request.AllowedLocations) {
        $locationBest = @($candidates | Where-Object Location -eq $location | Sort-Object MetricValue, AtUtc | Select-Object -First 1)[0]
        if ($locationBest) {
            Write-GateLog -Step 'Compare' -Message "$location best value: $($locationBest.MetricValue) $($locationBest.MetricUnit) at $(([datetime]$locationBest.AtUtc).ToUniversalTime().ToString('o'))."
        }
    }

    # Prefer the requested region only when candidates have the same lowest value.
    $bestValue = ($candidates | Measure-Object MetricValue -Minimum).Minimum
    $best = @($candidates |
        Where-Object MetricValue -eq $bestValue |
        Sort-Object @{ Expression = { if ($_.Location -eq $Request.PreferredLocation) { 0 } else { 1 } } }, AtUtc, Location)[0]
    $selectedAt = ([datetime]$best.AtUtc).ToUniversalTime()
    $status = if ($selectedAt -gt $now) { 'wait' } else { 'proceed' }
    Write-GateLog -Step 'Decision' -Message "Selected $($best.Location) at $($selectedAt.ToString('o')) with $($best.MetricValue) $($best.MetricUnit); response will be '$status'."

    [pscustomobject]@{
        Status = $status
        DecisionStatus = if ($status -eq 'wait') { 'Waiting' } else { 'Approved' }
        SelectedLocation = $best.Location
        StartType = if ($status -eq 'wait') { 'Delayed' } else { 'Immediate' }
        Reason = "Selected $($best.Location) at $($selectedAt.ToString('o')) using the lowest forecast $($best.MetricName)."
        MetricName = $best.MetricName
        MetricValue = $best.MetricValue
        MetricUnit = $best.MetricUnit
        DataSource = $best.DataSource
        DataPeriodStartUtc = $selectedAt
        DataPeriodEndUtc = $best.PeriodEndUtc
        CalculatedAtUtc = $now
        NotBeforeUtc = $selectedAt
        ValidUntilUtc = $now.AddMinutes([math]::Max(5, $Request.AllowedWaitMinutes + 5))
        EvaluationCount = 1
    }
}

# Convert a new decision to the flat entity shape stored in Azure Table Storage.
function New-DecisionEntity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Request,
        [Parameter(Mandatory)][pscustomobject]$Decision
    )

    $rowKey = ($Request.BuildId + '-' + $Request.Category) -replace '[^A-Za-z0-9_\-]', '_'
    [pscustomobject]@{
        PartitionKey = $Request.ProjectId
        RowKey = $rowKey
        DecisionId = "$($Request.ProjectId)-$($Request.BuildId)-$($Request.Category)"
        ProjectId = $Request.ProjectId
        BuildId = $Request.BuildId
        RepositoryId = $Request.RepositoryId
        Category = $Request.Category
        PreferredLocation = $Request.PreferredLocation
        AllowedLocations = $Request.AllowedLocations -join ','
        AllowedWaitMinutes = $Request.AllowedWaitMinutes
        SelectedLocation = $Decision.SelectedLocation
        StartType = $Decision.StartType
        DecisionStatus = $Decision.DecisionStatus
        Reason = $Decision.Reason
        MetricName = $Decision.MetricName
        MetricValue = $Decision.MetricValue
        MetricUnit = $Decision.MetricUnit
        DataSource = $Decision.DataSource
        DataPeriodStartUtc = ([datetime]$Decision.DataPeriodStartUtc).ToUniversalTime().ToString('o')
        DataPeriodEndUtc = ([datetime]$Decision.DataPeriodEndUtc).ToUniversalTime().ToString('o')
        CalculatedAtUtc = ([datetime]$Decision.CalculatedAtUtc).ToUniversalTime().ToString('o')
        NotBeforeUtc = ([datetime]$Decision.NotBeforeUtc).ToUniversalTime().ToString('o')
        ValidUntilUtc = ([datetime]$Decision.ValidUntilUtc).ToUniversalTime().ToString('o')
        EvaluationCount = 1
        LastEvaluatedUtc = ([datetime]$Decision.CalculatedAtUtc).ToUniversalTime().ToString('o')
        ApprovedAtUtc = if ($Decision.Status -eq 'proceed') { ([datetime]$Decision.CalculatedAtUtc).ToUniversalTime().ToString('o') } else { $null }
        FunctionVersion = '2.0.0'
        PolicyVersion = 'forecast-1'
    }
}
