# Input Parameters
param(
        [Parameter(Mandatory = $true)]
        [string]$appName,        
        [Parameter(Mandatory = $true)]
        [string]$clusterEndpoint,
        [Parameter(Mandatory = $true)]
        [string]$packagePath,
        [Parameter(Mandatory = $true)]
        [string]$imageStoreConnectionString,
        [string]$thumbprint,
        [bool]$forceRedeploy = $false,
        [bool]$forceRedeployWhenSameVersion = $false,
        [int]$maxConnectionAttempts = 1,
        [int]$attemptsWaitTime = 15 
)

function UpgradeServiceFabric 
{
    param(
    $ApplicationPackagePath,
    $ApplicationName,
    $ApplicationTypeName,
    $ApplicationTypeVersion,
    $imageStoreConnectionString,
    $CopyPackageTimeoutSec,
    $CompressPackage)


    ## Check existence of the application
    $oldApplication = Get-ServiceFabricApplication -ApplicationName $ApplicationName
        
    if (!$oldApplication) {
        $errMsg = "Application '$ApplicationName' doesn't exist in cluster."
        throw $errMsg
    }
    else {
        ## Check upgrade status
        $upgradeStatus = Get-ServiceFabricApplicationUpgrade -ApplicationName $ApplicationName
        if ($upgradeStatus.UpgradeState -ne "RollingBackCompleted" -and $upgradeStatus.UpgradeState -ne "RollingForwardCompleted" -and $upgradeStatus.UpgradeState -ne "Failed") {
            $errMsg = "An upgrade for the application '$ApplicationTypeName' is already in progress."
            throw $errMsg
        }

        $reg = Get-ServiceFabricApplicationType -ApplicationTypeName $ApplicationTypeName | Where-Object { $_.ApplicationTypeVersion -eq $ApplicationTypeVersion }
        if ($reg) {
            Write-Host 'Application Type '$ApplicationTypeName' and Version '$ApplicationTypeVersion' was already registered with Cluster, unregistering it...'
            $reg | Unregister-ServiceFabricApplicationType -Force
        }

        ## Copy application package to image store
        $applicationPackagePathInImageStore = $ApplicationTypeName
        Write-Host "Copying application package to image store..."
        Copy-ServiceFabricApplicationPackage -ApplicationPackagePath $ApplicationPackagePath -ImageStoreConnectionString $imageStoreConnectionString -ApplicationPackagePathInImageStore $applicationPackagePathInImageStore -TimeOutSec $CopyPackageTimeoutSec -CompressPackage:$CompressPackage 
        if (!$?) {
            throw "Copying of application package to image store failed. Cannot continue with registering the application."
        }
    
        ## Register application type
        Write-Host "Registering application type..."
        Register-ServiceFabricApplicationType -ApplicationPathInImageStore $applicationPackagePathInImageStore
        if (!$?) {
            throw "Registration of application type failed."
        }

        # Remove the application package to free system resources.
        Remove-ServiceFabricApplicationPackage -ImageStoreConnectionString $imageStoreConnectionString -ApplicationPackagePathInImageStore $applicationPackagePathInImageStore
        if (!$?) {
            Write-Host "Removing the application package failed."
        }
        
        ## Start monitored application upgrade
        try {
            Write-Host "Start upgrading application..." 

             Start-ServiceFabricApplicationUpgrade -ApplicationName $ApplicationName -ApplicationTypeVersion $ApplicationTypeVersion -HealthCheckStableDurationSec 0 -UpgradeDomainTimeoutSec 1200 -UpgradeTimeout 3000 -FailureAction Rollback -Monitored

        }
        catch {
            Write-Host ("Error starting upgrade. " + $_)

            Write-Host "Unregister application type '$ApplicationTypeName' and version '$ApplicationTypeVersion' ..."
            Unregister-ServiceFabricApplicationType -ApplicationTypeName $ApplicationTypeName -ApplicationTypeVersion $ApplicationTypeVersion -Force
            throw
        }

        do {
            Write-Host "Waiting for upgrade..."
            Start-Sleep -Seconds 3
            $upgradeStatus = Get-ServiceFabricApplicationUpgrade -ApplicationName $ApplicationName
        } while ($upgradeStatus.UpgradeState -ne "RollingBackCompleted" -and $upgradeStatus.UpgradeState -ne "RollingForwardCompleted" -and $upgradeStatus.UpgradeState -ne "Failed")
    
        if ($upgradeStatus.UpgradeState -eq "RollingForwardCompleted") {
            Write-Host "Upgrade completed successfully."
        }
        elseif ($upgradeStatus.UpgradeState -eq "RollingBackCompleted") {
            Write-Error "Upgrade was Rolled back."
        }
        elseif ($upgradeStatus.UpgradeState -eq "Failed") {
            Write-Error "Upgrade Failed."
        }


    }
}



$manifestFilePath = "$($packagePath)\ApplicationManifest.xml"

# Ensure that the deploying application manifest file exists.
if (Test-Path $manifestFilePath) {
        [xml]$cn = Get-Content "$($packagePath)\ApplicationManifest.xml"
        
        $deployingVersion = $cn.ApplicationManifest.ApplicationTypeVersion
        $connected = $false

        # Trying to connect to the cluster. 

        Write-Host "Trying to connect to the Service Fabric cluster located at $($clusterEndpoint)..."
        try {
                if ($thumbprint) {
                        Connect-ServiceFabricCluster -ConnectionEndpoint $clusterEndpoint -KeepAliveIntervalInSec 10 -X509Credential -ServerCertThumbprint $thumbprint -FindType FindByThumbprint -FindValue $thumbprint -StoreLocation LocalMachine -StoreName My
                }
                else {
                        Connect-ServiceFabricCluster -ConnectionEndpoint $clusterEndpoint
                }
                $connected = $true
        }
        catch {
                Write-Error "Unable to connect to the $($clusterEndpoint) Service Fabric Endpoint." 
              
        }

        # Connect to Service Fabric cluster

        if ($connected) {
                # Trying to get current application
                $currentApplication = Get-ServiceFabricApplication -ApplicationName "fabric:/$($appName)" 

                #if there is a current application already deployed
                if ($currentApplication -and -not $forceRedeploy) {
                        #if the version that is prepared to deploy is the same that is already deployed
                        if ($currentApplication.ApplicationTypeVersion -eq $deployingVersion) {

                                if ($forceRedeployWhenSameVersion) {
                                        Write-Warning "An Application '$($appName)' is already deployed for version '$($currentApplication.ApplicationTypeVersion)' and it will be deployed again."
                                        $forceRedeploy = $true
                                }
                                else {
                        
                                        Write-Warning "An Application '$($appName)' is already deployed for version '$($currentApplication.ApplicationTypeVersion)'. No changes were made."
                        
                                }
                        }
                        #if there is a new version to deploy then we need to upgrade the current application
                        else {
          
                                Write-Host "Preparing to upgrade $($appName) to version $($deployingVersion)..."        
                                UpgradeServiceFabric -ApplicationPackagePath $packagePath -ApplicationName "fabric:/$($appName)"  -ApplicationTypeName "$($appName)Type"  -ApplicationTypeVersion $deployingVersion -imageStoreConnectionString $imageStoreConnectionString -CopyPackageTimeoutSec 600 -CompressPackage $false        
                        }
        
                }
                if ($forceRedeploy -and $currentApplication) {
                        Write-Host "Preparing to remove current application version $($currentApplication.ApplicationTypeVersion)..."
                        Remove-ServiceFabricApplication -ApplicationName "fabric:/$($appName)" -Force
                        Unregister-ServiceFabricApplicationType -ApplicationTypeName $currentApplication.ApplicationTypeName -ApplicationTypeVersion $currentApplication.ApplicationTypeVersion -Force
                        $currentApplication = $null
                }


                if (-not $currentApplication) {
                        Write-Host "Preparing to deploy $($appName) version $($deployingVersion)..."

                        # Copy the application package to the cluster image store.
                        Copy-ServiceFabricApplicationPackage $packagePath -ImageStoreConnectionString $imageStoreConnectionString -ApplicationPackagePathInImageStore $appName

                        # Register the application type.
                        Register-ServiceFabricApplicationType -ApplicationPathInImageStore $appName

                        # Remove the application package to free system resources.
                        Remove-ServiceFabricApplicationPackage -ImageStoreConnectionString $imageStoreConnectionString -ApplicationPackagePathInImageStore $appName

                        # Create the application instance.
                        New-ServiceFabricApplication -ApplicationName "fabric:/$($appName)" -ApplicationTypeName "$($appName)Type" -ApplicationTypeVersion $deployingVersion

                        Write-Host "The application $($appName) was successfuly deployed (version $($deployingVersion))."
 
                }
        }
}
else {
        Write-Error "Manifest file $($manifestFilePath) was not found." 
}


