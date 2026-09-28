using namespace System.Net
param($Request, $TriggerMetadata)

# Azure Functions entry point.
#
# The code is deliberately written as six visible stages:
# 1. Validate the request.
# 2. Connect to Table Storage.
# 3. Look for an existing decision.
# 4. Determine the best region and moment, or reevaluate the stored decision.
# 5. Store the result.
# 6. Return wait/proceed to the deployment gate.
try {
    # Load the named helper functions. The main workflow remains visible below.
    . (Join-Path $PSScriptRoot 'GreenOpsGate.ps1')

    # -------------------------------------------------------------------------
    # Stage 1: Read and validate the request
    # -------------------------------------------------------------------------
    # Azure Functions can provide the body as JSON text or as an object. Convert
    # both forms into one validated object with predictable property names.
    $requestBody = if ($Request.Body -is [string]) {
        $Request.Body | ConvertFrom-Json -AsHashtable
    }
    else {
        $Request.Body
    }
    $gateRequest = ConvertFrom-GateRequest -InputObject $requestBody
    Write-GateLog -Step 'Request' -Message "Validated build '$($gateRequest.BuildId)' in category '$($gateRequest.Category)'; wait limit=$($gateRequest.AllowedWaitMinutes) minute(s)."

    # -------------------------------------------------------------------------
    # Stage 2: Connect to Azure Table Storage
    # -------------------------------------------------------------------------
    # The table stores one stable decision per project, build, and category.
    if ([string]::IsNullOrWhiteSpace($env:GREENOPS_STORAGE_ACCOUNT_NAME) -or [string]::IsNullOrWhiteSpace($env:GREENOPS_TABLE_NAME)) {
        throw 'GREENOPS_STORAGE_ACCOUNT_NAME and GREENOPS_TABLE_NAME must be configured.'
    }

    Write-GateLog -Step 'Storage' -Message 'Connecting to Table Storage with the Function App managed identity.'
    $accessToken = Get-AzAccessToken -ResourceUrl 'https://storage.azure.com/'
    $token = if ($accessToken.Token -is [securestring]) {
        $tokenPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($accessToken.Token)
        try {
            [Runtime.InteropServices.Marshal]::PtrToStringBSTR($tokenPointer)
        }
        finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($tokenPointer)
        }
    }
    else {
        [string]$accessToken.Token
    }

    $tableUri = "https://$($env:GREENOPS_STORAGE_ACCOUNT_NAME).table.core.windows.net/$($env:GREENOPS_TABLE_NAME)"
    $tableHeaders = @{
        Authorization = "Bearer $token"
        Accept = 'application/json;odata=nometadata'
        'x-ms-version' = '2019-02-02'
    }
    Write-GateLog -Step 'Host' -Message "Table Storage client ready for table '$($env:GREENOPS_TABLE_NAME)'."

    # -------------------------------------------------------------------------
    # Stage 3: Check whether this build already has a decision
    # -------------------------------------------------------------------------
    # Azure DevOps polls the function repeatedly. Reusing the first decision
    # prevents the selected time or region from changing between poll requests.
    $partitionKey = $gateRequest.ProjectId
    $rowKey = ($gateRequest.BuildId + '-' + $gateRequest.Category) -replace '[^A-Za-z0-9_\-]', '_'
    Write-GateLog -Step 'Storage' -Message "Looking up decision with PartitionKey '$partitionKey' and RowKey '$rowKey'."
    $existingDecision = Get-StoredDecision `
        -TableUri $tableUri `
        -Headers $tableHeaders `
        -PartitionKey $partitionKey `
        -RowKey $rowKey
    Write-GateLog -Step 'Storage' -Message $(if ($existingDecision) { 'Stored decision found.' } else { 'No stored decision found.' })

    # -------------------------------------------------------------------------
    # Stage 4: Determine the response
    # -------------------------------------------------------------------------
    # For a new build, this compares the allowed regions and forecast moments.
    # For a known build, it checks whether NotBeforeUtc has been reached.
    $decision = Get-DeploymentDecision `
        -Request $gateRequest `
        -ExistingDecision $existingDecision

    if ($existingDecision) {
        $decisionEntity = $decision
    }
    else {
        $decisionEntity = New-DecisionEntity -Request $gateRequest -Decision $decision
    }

    # -------------------------------------------------------------------------
    # Stage 5: Store the decision before returning it
    # -------------------------------------------------------------------------
    # Saving first guarantees that every response shown to the pipeline has a
    # matching audit record. PUT inserts a new entity or replaces an existing one.
    $storageAction = if ($existingDecision) { 'Updating' } else { 'Creating' }
    Write-GateLog -Step 'Storage' -Message "$storageAction decision record with status '$($decision.DecisionStatus)'."
    Save-Decision -TableUri $tableUri -Headers $tableHeaders -Entity $decisionEntity
    Write-GateLog -Step 'Storage' -Message 'Decision record stored successfully.'

    # -------------------------------------------------------------------------
    # Stage 6: Build the small response expected by the deployment gate
    # -------------------------------------------------------------------------
    $responseBody = [pscustomobject]@{
        status = $decision.Status
        decisionId = "$($gateRequest.ProjectId)-$($gateRequest.BuildId)-$($gateRequest.Category)"
        selectedLocation = $decision.SelectedLocation
        calculatedAtUtc = ([datetime]$decisionEntity.CalculatedAtUtc).ToUniversalTime().ToString('o')
        notBeforeUtc = ([datetime]$decision.NotBeforeUtc).ToUniversalTime().ToString('o')
        approvedAtUtc = if ($decisionEntity.PSObject.Properties.Name -contains 'ApprovedAtUtc' -and $decisionEntity.ApprovedAtUtc) {
            ([datetime]$decisionEntity.ApprovedAtUtc).ToUniversalTime().ToString('o')
        }
        else {
            $null
        }
        reason = $decision.Reason
    }
    Write-GateLog -Step 'Response' -Message "Returning '$($decision.Status)' for $($decision.SelectedLocation); notBeforeUtc=$($responseBody.notBeforeUtc)."

    # Azure DevOps reads this JSON body to decide whether it should wait or proceed.
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body = $responseBody | ConvertTo-Json -Depth 5
        Headers = @{ 'Content-Type' = 'application/json' }
    })
}
catch {
    # Invalid caller input is a 400. Azure, storage, and ENTSO-E failures are 500s.
    $statusCode = if ($_.Exception -is [System.ArgumentException]) {
        [HttpStatusCode]::BadRequest
    }
    else {
        [HttpStatusCode]::InternalServerError
    }
    Write-Error $_.Exception.Message
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = $statusCode
        Body = @{ status = 'error'; reason = $_.Exception.Message } | ConvertTo-Json
        Headers = @{ 'Content-Type' = 'application/json' }
    })
}
