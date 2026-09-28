[CmdletBinding()]
param(
	[ValidateSet('hotfix', 'test', 'production')]
	[string]$Category = $env:GREENOPS_CATEGORY,

	[string]$StorageAccountName = $env:GREENOPS_STORAGE_ACCOUNT_NAME,

	[string]$TableName = $env:GREENOPS_TABLE_NAME,

	[string]$AccessToken = $env:GREENOPS_STORAGE_ACCESS_TOKEN
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Stage 1: Read the Azure DevOps build identity
# -----------------------------------------------------------------------------
$buildId = $env:BUILD_BUILDID
$projectId = $env:SYSTEM_TEAMPROJECTID

if ([string]::IsNullOrWhiteSpace($buildId) -or
	[string]::IsNullOrWhiteSpace($projectId) -or
	[string]::IsNullOrWhiteSpace($Category) -or
	[string]::IsNullOrWhiteSpace($StorageAccountName) -or
	[string]::IsNullOrWhiteSpace($TableName)) {
	throw 'The Azure DevOps build identity and Table Storage settings are required.'
}

# -----------------------------------------------------------------------------
# Stage 2: Build the key used by the Function when it stored the decision
# -----------------------------------------------------------------------------
$rowKey = ($buildId + '-' + $Category) -replace '[^A-Za-z0-9_\-]', '_'

Write-Host "Reading the approved GreenOps decision for build '$buildId'."

# -----------------------------------------------------------------------------
# Stage 3: Retrieve and validate the stored decision
# -----------------------------------------------------------------------------
$decision = & (Join-Path $PSScriptRoot 'Get-StoredGreenOpsDecision.ps1') `
	-StorageAccountName $StorageAccountName `
	-TableName $TableName `
	-PartitionKey $projectId `
	-RowKey $rowKey `
	-AccessToken $AccessToken

if ($decision.DecisionStatus -ne 'Approved') {
	throw "Stored GreenOps decision is not approved: $($decision.DecisionStatus) - $($decision.Reason)"
}

# -----------------------------------------------------------------------------
# Stage 4: Print an audit-friendly summary and expose the selected region
# -----------------------------------------------------------------------------
$notBeforeUtc = ([datetime]$decision.NotBeforeUtc).ToUniversalTime()
$calculatedAtUtc = ([datetime]$decision.CalculatedAtUtc).ToUniversalTime()
$scheduledWait = $notBeforeUtc - $calculatedAtUtc
$waitMinutes = [math]::Floor([math]::Max(0, $scheduledWait.TotalMinutes))
$waitSeconds = [math]::Max(0, $scheduledWait.Seconds)
$waitDescription = "$waitMinutes minute(s), $waitSeconds second(s)"
$actualWaitDescription = 'Not recorded'

if ($decision.ApprovedAtUtc) {
	$approvedAtUtc = ([datetime]$decision.ApprovedAtUtc).ToUniversalTime()
	$actualWait = $approvedAtUtc - $calculatedAtUtc
	$actualWaitMinutes = [math]::Floor([math]::Max(0, $actualWait.TotalMinutes))
	$actualWaitSeconds = [math]::Max(0, $actualWait.Seconds)
	$actualWaitDescription = "$actualWaitMinutes minute(s), $actualWaitSeconds second(s)"
}

Write-Host ''
Write-Host '##[section]GreenOps deployment approved'
Write-Host '------------------------------------------------------------'
Write-Host "Status             : $($decision.DecisionStatus)"
Write-Host "Selected region    : $($decision.SelectedLocation)"
Write-Host "Deployment category: $Category"
Write-Host "Scheduled wait     : $waitDescription"
Write-Host "Actual gate wait   : $actualWaitDescription"
Write-Host "Eligible from UTC  : $($notBeforeUtc.ToString('u'))"
Write-Host "Decision ID        : $($decision.DecisionId)"
Write-Host "Reason             : $($decision.Reason)"
Write-Host '------------------------------------------------------------'

Write-Host "##vso[task.setvariable variable=SelectedLocation]$($decision.SelectedLocation)"
