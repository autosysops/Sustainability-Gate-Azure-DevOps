[CmdletBinding()]
param(
	[Parameter(Mandatory)]
	[string]$StorageAccountName,

	[Parameter(Mandatory)]
	[string]$TableName,

	[Parameter(Mandatory)]
	[string]$PartitionKey,

	[Parameter(Mandatory)]
	[string]$RowKey,

	[string]$AccessToken
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Stage 1: Use the Azure service connection to request a Storage data token.
if ([string]::IsNullOrWhiteSpace($AccessToken)) {
	$AccessToken = az account get-access-token `
		--resource 'https://storage.azure.com/' `
		--query accessToken `
		--output tsv

	if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($AccessToken)) {
		throw 'Could not obtain an Azure Storage token from the service connection.'
	}
}

# Stage 2: Build the address of the one entity created by the approval gate.
$safePartitionKey = $PartitionKey.Replace("'", "''")
$safeRowKey = $RowKey.Replace("'", "''")
$entityUri = "https://$StorageAccountName.table.core.windows.net/$TableName(PartitionKey='$safePartitionKey',RowKey='$safeRowKey')"
$headers = @{
	Authorization = "Bearer $AccessToken"
	Accept = 'application/json;odata=nometadata'
	'x-ms-version' = '2019-02-02'
}

# Stage 3: Read the stored decision. This is read-only and never recalculates it.
Write-Host "Reading decision '$RowKey' from Azure Table Storage."
try {
	Invoke-RestMethod `
		-Method Get `
		-Uri $entityUri `
		-Headers $headers
}
catch {
	$statusCode = if ($_.Exception.Response) {
		[int]$_.Exception.Response.StatusCode
	}
	else {
		0
	}

	if ($statusCode -eq 403) {
		throw "The Azure service connection cannot read Table Storage. Grant it 'Storage Table Data Reader' on storage account '$StorageAccountName'."
	}
	if ($statusCode -eq 404) {
		throw "No GreenOps decision was found for build row '$RowKey'."
	}

	throw
}