param (
  [string] $imageKey,
  [string] $group
)

# job settings. change these for the tasks at hand.
#$VerbosePreference = 'continue';
$targetCloudPlatform = 'azure';
$workFolder = (Resolve-Path -Path ('{0}\..' -f $PSScriptRoot));

# constants and script config. these are probably ok as they are.
$revision = $(& git rev-parse HEAD);
if (@(Get-PSRepository -Name 'PSGallery')[0].InstallationPolicy -ne 'Trusted') {
  Set-PSRepository -Name 'PSGallery' -InstallationPolicy 'Trusted';
}
foreach ($rm in @(
  @{ 'module' = 'posh-minions-managed'; 'version' = '0.0.62' },
  @{ 'module' = 'powershell-yaml'; 'version' = '0.4.1' }
)) {
  $module = (Get-Module -Name $rm.module -ErrorAction SilentlyContinue);
  if ($module) {
    if ($module.Version -lt $rm.version) {
      Update-Module $rm.module -RequiredVersion $rm.version;
    }
  } else {
    Install-Module $rm.module -RequiredVersion $rm.version -AllowClobber;
  }
  Import-Module $rm.module -RequiredVersion $rm.version -ErrorAction SilentlyContinue;
}
Write-Output -InputObject ('workFolder: {0}, revision: {1}, targetCloudPlatform: {2}, imageKey: {3}' -f $workFolder, $revision, $targetCloudPlatform, $imageKey);

$secret = (Invoke-WebRequest -Uri 'http://taskcluster/secrets/v1/secret/project/relops/image-builder/dev' -UseBasicParsing | ConvertFrom-Json).secret;
Set-AWSCredential `
  -AccessKey $secret.amazon.id `
  -SecretKey $secret.amazon.key `
  -StoreAs 'default' | Out-Null;

Connect-AzAccount `
  -ServicePrincipal `
  -Credential (New-Object System.Management.Automation.PSCredential($secret.azure.id, (ConvertTo-SecureString `
    -String $secret.azure.key `
    -AsPlainText `
    -Force))) `
  -Tenant $secret.azure.account | Out-Null;

$azcopyExePath = ('{0}\azcopy.exe' -f $workFolder);
$azcopyZipPath = ('{0}\azcopy.zip' -f $workFolder);
$azcopyZipUrl = 'https://aka.ms/downloadazcopy-v10-windows';
if (-not (Test-Path -Path $azcopyExePath -ErrorAction SilentlyContinue)) {
  (New-Object Net.WebClient).DownloadFile($azcopyZipUrl, $azcopyZipPath);
  if (Test-Path -Path $azcopyZipPath -ErrorAction SilentlyContinue) {
    Write-Output -InputObject ('downloaded: {0} from: {1}' -f $azcopyZipPath, $azcopyZipUrl);
    Expand-Archive -Path $azcopyZipPath -DestinationPath $workFolder;
    try {
      $extractedAzcopyExePath = (@(Get-ChildItem -Path ('{0}\azcopy.exe' -f $workFolder) -Recurse -ErrorAction SilentlyContinue -Force)[0].FullName);
      Write-Output -InputObject ('extracted: {0} from: {1}' -f $extractedAzcopyExePath, $azcopyZipPath);
      Copy-Item -Path $extractedAzcopyExePath -Destination $azcopyExePath;
      if (Test-Path -Path $azcopyExePath -ErrorAction SilentlyContinue) {
        Write-Output -InputObject ('copied: {0} to: {1}' -f $extractedAzcopyExePath, $azcopyExePath);
        $env:PATH = ('{0};{1}' -f $env:PATH, $workFolder);
        [Environment]::SetEnvironmentVariable('PATH', $env:PATH, 'User');
        Write-Output -InputObject ('user env PATH set to: {0}' -f $env:PATH);
      }
    } catch {
      Write-Output -InputObject ('failed to extract azcopy from: {0}' -f $azcopyZipPath);
    }
  }
}

# computed target specific settings. these are probably ok as they are.
$config = (Get-Content -Path ('{0}\cloud-image-builder\config\{1}.yaml' -f $workFolder, $imageKey) -Raw | ConvertFrom-Yaml);
if (-not ($config)) {
  Write-Output -InputObject ('error: failed to find image config for {0}' -f $imageKey);
  exit 1
}
$imageArtifactDescriptorUri = ('https://firefox-ci-tc.services.mozilla.com/api/index/v1/task/project.relops.cloud-image-builder.{0}.{1}.latest/artifacts/public/image-bucket-resource.json' -f $targetCloudPlatform, $imageKey.Replace(('-{0}' -f $targetCloudPlatform), ''));
try {
  $memoryStream = (New-Object System.IO.MemoryStream(, (New-Object System.Net.WebClient).DownloadData($imageArtifactDescriptorUri)));
  $streamReader = (New-Object System.IO.StreamReader(New-Object System.IO.Compression.GZipStream($memoryStream, [System.IO.Compression.CompressionMode] 'Decompress')))
  $imageArtifactDescriptor = ($streamReader.ReadToEnd() | ConvertFrom-Json);
  Write-Output -InputObject ('fetched disk image config for: {0}, from: {1}' -f $imageKey, $imageArtifactDescriptorUri);
} catch {
  Write-Output -InputObject ('error: failed to decompress or parse json from: {0}. {1}' -f $imageArtifactDescriptorUri, $_.Exception.Message);
  exit 1
}
$exportImageName = [System.IO.Path]::GetFileName($imageArtifactDescriptor.image.key);
$vhdLocalPath = ('{0}{1}{2}' -f $workFolder, ([IO.Path]::DirectorySeparatorChar), $exportImageName);

foreach ($target in @($config.target | ? { (($_.platform -eq $targetCloudPlatform) -and $_.group -eq $group) })) {
  $importImageName = ('{0}-{1}-{2}' -f $target.group.Replace('rg-', ''), $imageKey.Replace(('-{0}' -f $targetCloudPlatform), ''), $imageArtifactDescriptor.build.revision.Substring(0, 7));
  $existingImage = (Get-AzImage `
    -ResourceGroupName $target.group `
    -ImageName $importImageName `
    -ErrorAction SilentlyContinue);
  if ($existingImage) {
    Write-Output -InputObject ('skipped machine image creation for: {0}, in group: {1}, in cloud platform: {2}. machine image exists' -f $importImageName, $target.group, $target.platform);
    exit;
  } else {
    # check if the image exists in another regional resource-group
    foreach ($alternateTarget in @($config.target | ? { (($_.platform -eq $targetCloudPlatform) -and $_.group -ne $group) })) {
      $alternateImageName = ('{0}-{1}-{2}' -f $alternateTarget.group.Replace('rg-', ''), $imageKey.Replace(('-{0}' -f $targetCloudPlatform), ''), $imageArtifactDescriptor.build.revision.Substring(0, 7));
      $alternateImage = (Get-AzImage `
        -ResourceGroupName $alternateTarget.group `
        -ImageName $alternateImageName `
        -ErrorAction SilentlyContinue);
      if ($alternateImage) {
        Write-Output -InputObject ('found machine image for: {0}, in group: {1}, in cloud platform: {2}. triggering machine image copy from {1} to {3}...' -f $importImageName, $alternateTarget.group, $alternateTarget.platform, $target.group);
        # todo implement image copy here...
        exit;
      }
    }
  }
  if (-not (Test-Path -Path $vhdLocalPath -ErrorAction SilentlyContinue)) {
    Get-CloudBucketResource `
      -platform $imageArtifactDescriptor.image.platform `
      -bucket $imageArtifactDescriptor.image.bucket `
      -key $imageArtifactDescriptor.image.key `
      -destination $vhdLocalPath `
      -force;
    if (Test-Path -Path $vhdLocalPath -ErrorAction SilentlyContinue) {
      Write-Output -InputObject ('download success for: {0} from: {1}/{2}/{3}' -f $vhdLocalPath, $imageArtifactDescriptor.image.platform, $imageArtifactDescriptor.image.bucket, $imageArtifactDescriptor.image.key);
    } else {
      Write-Output -InputObject ('download failure for: {0} from: {1}/{2}/{3}' -f $vhdLocalPath, $imageArtifactDescriptor.image.platform, $imageArtifactDescriptor.image.bucket, $imageArtifactDescriptor.image.key);
      exit 1;
    }
  }

  $sku = ($target.machine.format -f $target.machine.cpu);
  if (-not (Get-AzComputeResourceSku | where { (($_.Locations -icontains $target.region.Replace(' ', '').ToLower()) -and ($_.Name -eq $sku)) })) {
    Write-Output -InputObject ('skipped image export: {0}, to region: {1}, in cloud platform: {2}. {3} is not available' -f $exportImageName, $target.region, $target.platform, $sku);
    exit 1;
  } else {
    switch -regex ($sku) {
      '^Basic_A[0-9]+$' {
        $skuFamily = 'Basic A Family vCPUs';
        break;
      }
      '^Standard_A[0-7]$' {
        $skuFamily = 'Standard A0-A7 Family vCPUs';
        break;
      }
      '^Standard_A(8|9|10|11)$' {
        $skuFamily = 'Standard A8-A11 Family vCPUs';
        break;
      }
      '^(Basic|Standard)_(B|D|E|F|H|L|M)[0-9]+m?r?$' {
        $skuFamily = '{0} {1} Family vCPUs' -f $matches[1], $matches[2];
        break;
      }
      '^(Basic|Standard)_(A|B|D|E|F|H|L|M)[0-9]+m?r?_Promo$' {
        $skuFamily = '{0} {1} Promo Family vCPUs' -f $matches[1], $matches[2];
        break;
      }
      '^(Basic|Standard)_(A|B|D|E|F|H|L|M)[0-9]+[lmt]?s$' {
        $skuFamily = '{0} {1}S Family vCPUs' -f $matches[1], $matches[2];
        break;
      }
      '^(Basic|Standard)_(A|B|D|E|F|H|L|M|P)([BC])[0-9]+r?s$' {
        $skuFamily = '{0} {1}{2}S Family vCPUs' -f $matches[1], $matches[2], $matches[3];
        break;
      }
      '^(Basic|Standard)_(A|B|D|E|F|H|L|M)[0-9]+(-(1|2|4|8|16|32|64))?m?s$' {
        $skuFamily = '{0} {1}S Family vCPUs' -f $matches[1], $matches[2];
        break;
      }
      '^(Basic|Standard)_(A|B|D|E|F|H|L|M)S[0-9]+$' {
        $skuFamily = '{0} {1}S Family vCPUs' -f $matches[1], $matches[2];
        break;
      }
      '^(Basic|Standard)_(A|B|D|E|F|H|L|M)1?[0-9]+m?_v([2-4])$' {
        $skuFamily = '{0} {1}v{2} Family vCPUs' -f $matches[1], $matches[2], $matches[3];
        break;
      }
      '^(Basic|Standard)_(A|B|D|E|F|H|L|M)?[0-9]+_v([2-4])_Promo$' {
        $skuFamily = '{0} {1}v{2} Promo Family vCPUs' -f $matches[1], $matches[2], $matches[3];
        break;
      }
      '^(Basic|Standard)_(A|B|D|E|F|H|L|M)1?[0-9]+_v([2-4])$' {
        $skuFamily = '{0} {1}v{2} Family vCPUs' -f $matches[1], $matches[2], $matches[3];
        break;
      }
      '^(Basic|Standard)_(A|B|D|E|F|H|L|M)1?[0-9]+m?s_v([2-4])$' {
        $skuFamily = '{0} {1}Sv{2} Family vCPUs' -f $matches[1], $matches[2], $matches[3];
        break;
      }
      '^(Basic|Standard)_(A|B|D|E|F|H|L|M)[0-9]+(-(1|2|4|8|16|32|64))?s_v([2-4])$' {
        $skuFamily = '{0} {1}Sv{2} Family vCPUs' -f $matches[1], $matches[2], $matches[5];
        break;
      }
      '^(Basic|Standard)_(A|B|D|E|F|H|L|M)S[0-9]+(-(1|2|4|8|16|32|64))?_v([2-4])$' {
        $skuFamily = '{0} {1}Sv{2} Family vCPUs' -f $matches[1], $matches[2], $matches[5];
        break;
      }
      '^(Basic|Standard)_(A|B|D|E|F|H|L|M)[0-9]+(-(1|2|4|8|16|32|64))?i_v([2-4])$' {
        $skuFamily = '{0} {1}Iv{2} Family vCPUs' -f $matches[1], $matches[2], $matches[5];
        break;
      }
      '^(Basic|Standard)_(A|B|D|E|F|H|L|M)[0-9]+(-(1|2|4|8|16|32|64))?is_v([2-4])$' {
        $skuFamily = '{0} {1}ISv{2} Family vCPUs' -f $matches[1], $matches[2], $matches[5];
        break;
      }
      '^(Basic|Standard)_(A|B|D|E|F|H|L|M)S[0-9]+_v([2-4])_Promo$' {
        $skuFamily = '{0} {1}Sv{2} Promo Family vCPUs' -f $matches[1], $matches[2], $matches[3];
        break;
      }
      '^(Basic|Standard)_(A|B|D|E|F|H|L|M)1?[0-9]+a_v([2-4])$' {
        $skuFamily = '{0} {1}Av{2} Family vCPUs' -f $matches[1], $matches[2], $matches[3];
        break;
      }
      '^(Basic|Standard)_(A|B|D|E|F|H|L|M)1?[0-9]+as_v([2-4])$' {
        $skuFamily = '{0} {1}ASv{2} Family vCPUs' -f $matches[1], $matches[2], $matches[3];
        break;
      }
      '^Standard_N([CV])[0-9]+r?$' {
        $skuFamily = 'Standard N{0} Family vCPUs' -f $matches[1];
        break;
      }
      '^Standard_N([CV])[0-9]+r?_Promo$' {
        $skuFamily = 'Standard N{0} Promo Family vCPUs' -f $matches[1];
        break;
      }
      '^Standard_N([DP])S[0-9]+$' {
        $skuFamily = 'Standard N{0}S Family vCPUs' -f $matches[1];
        break;
      }
      '^Standard_N([DP])[0-9]+r?s$' {
        $skuFamily = 'Standard N{0}S Family vCPUs' -f $matches[1];
        break;
      }
      '^Standard_N([CDV])[0-9]+r?s_v([2-4])$' {
        $skuFamily = 'Standard N{0}Sv{1} Family vCPUs' -f $matches[1], $matches[2];
        break;
      }
      default {
        $skuFamily = $false;
        break;
      }
    }
    if ($skuFamily) {
      Write-Output -InputObject ('mapped machine sku: {0}, to machine family: {1}' -f $sku, $skuFamily);
      $azVMUsage = @(Get-AzVMUsage -Location $target.region | ? { $_.Name.LocalizedValue -eq $skuFamily })[0];
    } else {
      Write-Output -InputObject ('failed to map machine sku: {0}, to machine family (no regex match)' -f $sku);
      $azVMUsage = $false;
      exit 1;
    }
    if (-not $azVMUsage) {
      Write-Output -InputObject ('skipped image export: {0}, to region: {1}, in cloud platform: {2}. failed to obtain vm usage for machine sku: {3}, family: {4}' -f $exportImageName, $target.region, $target.platform, $sku, $skuFamily);
      exit 1;
    } elseif ($azVMUsage.Limit -lt ($azVMUsage.CurrentValue + $target.machine.cpu)) {
      Write-Output -InputObject ('skipped image export: {0}, to region: {1}, in cloud platform: {2}. {3}/{4} cores quota in use for machine sku: {5}, family: {6}. no capacity for requested aditional {7} cores' -f $exportImageName, $target.region, $target.platform, $azVMUsage.CurrentValue, $azVMUsage.Limit, $sku, $skuFamily, $target.machine.cpu);
      exit 123;
    } else {
      Write-Output -InputObject ('quota usage check: usage limit: {0}, usage current value: {1}, core request: {2}, for machine sku: {3}, family: {4}' -f $azVMUsage.Limit, $azVMUsage.CurrentValue, $target.machine.cpu, $sku, $skuFamily);
      try {
        Write-Output -InputObject ('begin image export: {0}, to region: {1}, in cloud platform: {2}' -f $exportImageName, $target.region, $target.platform);
        switch ($target.hostname.slug.type) {
          'uuid' {
            $resourceId = (([Guid]::NewGuid()).ToString().Substring((36 - $target.hostname.slug.length)));
            $instanceName = ($target.hostname.format -f $resourceId);
            break;
          }
          default {
            $resourceId = (([Guid]::NewGuid()).ToString().Substring(24));
            $instanceName = ('vm-{0}' -f $resourceId);
            break;
          }
        }
        $osDiskConfig = (@($target.disk | ? { $_.os })[0]);
        $tags = @{
          'diskImageBuildRevision' = $imageArtifactDescriptor.build.revision;
          'machineImageBuildRevision' = $revision;
          'imageKey' = $imageKey;
          'resourceId' = $resourceId;
          'sourceIso' = ([System.IO.Path]::GetFileName($config.iso.source.key))
        };
        foreach ($tag in $target.tag) {
          $tags[$tag.name] = $tag.value;
        }
        # todo: get instance screenshots
        New-CloudInstanceFromImageExport `
          -platform $target.platform `
          -localImagePath $vhdLocalPath `
          -targetResourceId $resourceId `
          -targetResourceGroupName $target.group `
          -targetResourceRegion $target.region `
          -targetInstanceMachineVariantFormat $target.machine.format `
          -targetInstanceCpuCount $target.machine.cpu `
          -targetInstanceRamGb $target.machine.ram `
          -targetInstanceName $instanceName `
          -targetInstanceDiskVariant $osDiskConfig.variant `
          -targetInstanceDiskSizeGb $osDiskConfig.size `
          -targetInstanceTags $tags `
          -targetVirtualNetworkName $target.network.name `
          -targetVirtualNetworkAddressPrefix $target.network.prefix `
          -targetVirtualNetworkDnsServers $target.network.dns `
          -targetSubnetName $target.network.subnet.name `
          -targetSubnetAddressPrefix $target.network.subnet.prefix

        do {
          $azVm = (Get-AzVm -ResourceGroupName $target.group -Name $instanceName -ErrorAction SilentlyContinue);
          if ($azVm) {
            if (@('Succeeded', 'Failed') -contains $azVm.ProvisioningState) {
              Write-Output -InputObject ('provisioning of vm: {0}, {1}' -f $instanceName, $azVm.ProvisioningState.ToLower());
            } else {
              Write-Output -InputObject ('provisioning of vm: {0}, in progress with state: {1}' -f $instanceName, $azVm.ProvisioningState.ToLower());
              Start-Sleep -Seconds 60
            }
          } else {
            Write-Output -InputObject ('provisioning of vm: {0}, failed before it started' -f $instanceName);
            exit 123;
          }
        } until ((-not $azVm) -or (@('Succeeded', 'Failed') -contains $azVm.ProvisioningState))
        Write-Output -InputObject ('end image export: {0} to: {1} cloud platform' -f $exportImageName, $target.platform);

        if ($azVm -and ($azVm.ProvisioningState -eq 'Succeeded')) {
          Write-Output -InputObject ('begin image import: {0} in region: {1}, cloud platform: {2}' -f $importImageName, $target.region, $target.platform);

          (New-Object Net.WebClient).DownloadFile('https://raw.githubusercontent.com/mozilla-releng/OpenCloudConfig/azure/userdata/rundsc.ps1', ('{0}\rundsc.ps1' -f $env:Temp));

          # the first time occ runs, it renames the instance and reboots
          $firstOccTriggerCommandResult = (Invoke-AzVMRunCommand `
            -ResourceGroupName $target.group `
            -VMName $instanceName `
            -CommandId 'RunPowerShellScript' `
            -ScriptPath ('{0}\rundsc.ps1' -f $env:Temp)); #-Parameter @{"arg1" = "var1";"arg2" = "var2"}
          Write-Output -InputObject ('first occ trigger {0} on instance: {1} in region: {2}, cloud platform: {3}' -f $firstOccTriggerCommandResult.Status.ToLower(), $instanceName, $target.region, $target.platform);
          Write-Output -InputObject ('first occ trigger std out: {0}' -f $firstOccTriggerCommandResult.Value[0].Message);
          Write-Output -InputObject ('first occ trigger std err: {0}' -f $firstOccTriggerCommandResult.Value[1].Message);

          if ($firstOccTriggerCommandResult.Status -eq 'Succeeded') {

            Set-Content -Path ('{0}\computername.ps1' -f $env:Temp) -Value '$env:ComputerName';
            $echoHostnameCommandOutput = '';
            do {
              $echoHostnameResult = (Invoke-AzVMRunCommand `
                -ResourceGroupName $target.group `
                -VMName $instanceName `
                -CommandId 'RunPowerShellScript' `
                -ScriptPath ('{0}\computername.ps1' -f $env:Temp) `
                -ErrorAction SilentlyContinue);
              Write-Output -InputObject ('echo hostname {0} on instance: {1} in region: {2}, cloud platform: {3}' -f $echoHostnameResult.Status.ToLower(), $instanceName, $target.region, $target.platform);
              if ($echoHostnameResult.Value) {
                $echoHostnameCommandOutput = $echoHostnameResult.Value[0].Message;
                Write-Output -InputObject ('echo hostname std out: {0}' -f $echoHostnameResult.Value[0].Message);
                Write-Output -InputObject ('echo hostname std err: {0}' -f $echoHostnameResult.Value[1].Message);
              } else {
                Write-Output -InputObject 'echo hostname command did not return a value';
              }
              if ($echoHostnameCommandOutput -match $instanceName) {
                Write-Output -InputObject ('host rename to: {0}, detected' -f $instanceName);
              } else {
                Write-Output -InputObject ('awaiting host rename to: {0}' -f $instanceName);
                Start-Sleep -Seconds 30;
              }
            } until ($echoHostnameCommandOutput -match $instanceName)
            Remove-Item -Path ('{0}\computername.ps1' -f $env:Temp);
            # todo: validate that the instance rebooted after the host rename.

            # the second time occ runs, it invokes dsc
            $secondOccTriggerCommandResult = (Invoke-AzVMRunCommand `
              -ResourceGroupName $target.group `
              -VMName $instanceName `
              -CommandId 'RunPowerShellScript' `
              -ScriptPath ('{0}\rundsc.ps1' -f $env:Temp));
            Remove-Item -Path ('{0}\rundsc.ps1' -f $env:Temp);

            Write-Output -InputObject ('seccond occ trigger {0} on instance: {1} in region: {2}, cloud platform: {3}' -f $secondOccTriggerCommandResult.Status.ToLower(), $instanceName, $target.region, $target.platform);
            Write-Output -InputObject ('seccond occ trigger std out: {0}' -f $secondOccTriggerCommandResult.Value[0].Message);
            Write-Output -InputObject ('seccond occ trigger std err: {0}' -f $secondOccTriggerCommandResult.Value[1].Message);

            if ($secondOccTriggerCommandResult.Status -eq 'Succeeded') {

              Set-Content -Path ('{0}\dirdsc.ps1' -f $env:Temp) -Value 'Get-ChildItem -Path "C:\dsc"';
              $dirDscCommandOutput = '';
              $dirDscIteration = 0;
              do {
                $dirDscResult = (Invoke-AzVMRunCommand `
                  -ResourceGroupName $target.group `
                  -VMName $instanceName `
                  -CommandId 'RunPowerShellScript' `
                  -ScriptPath ('{0}\dirdsc.ps1' -f $env:Temp) `
                  -ErrorAction SilentlyContinue);
                Write-Output -InputObject ('dir dsc (iteration {0}) command {1} on instance: {2} in region: {3}, cloud platform: {4}' -f $dirDscIteration, $dirDscResult.Status.ToLower(), $instanceName, $target.region, $target.platform);
                if ($dirDscResult.Value) {
                  $dirDscCommandOutput = $dirDscResult.Value[0].Message;
                  Write-Output -InputObject ('dir dsc (iteration {0}) std out: {1}' -f $dirDscIteration, $dirDscResult.Value[0].Message);
                  Write-Output -InputObject ('dir dsc (iteration {0}) std err: {1}' -f $dirDscIteration, $dirDscResult.Value[1].Message);
                } else {
                  Write-Output -InputObject ('dir dsc (iteration {0}) command did not return a value' -f $dirDscIteration);
                }
                if ($dirDscCommandOutput -match 'task-claim-state.valid') {
                  Write-Output -InputObject ('dir dsc (iteration {0}) detected occ completion on: {1}' -f $dirDscIteration, $instanceName);
                } else {
                  Write-Output -InputObject ('dir dsc (iteration {0}) awaiting occ completion on: {1}' -f $dirDscIteration, $instanceName);
                  Start-Sleep -Seconds 30;
                }
                $dirDscIteration += 1;
              } until ($dirDscCommandOutput -match 'task-claim-state.valid')
              Remove-Item -Path ('{0}\dirdsc.ps1' -f $env:Temp);

              New-CloudImageFromInstance `
                -platform $target.platform `
                -resourceGroupName $target.group `
                -region $target.region `
                -instanceName $instanceName `
                -imageName $importImageName;

              try {
                $azImage = (Get-AzImage `
                  -ResourceGroupName $target.group `
                  -ImageName $importImageName `
                  -ErrorAction SilentlyContinue);
                if ($azImage) {
                  Write-Output -InputObject ('image: {0}, creation appears successful in region: {1}, cloud platform: {2}' -f $importImageName, $target.region, $target.platform);
                } else {
                  Write-Output -InputObject ('image: {0}, creation appears unsuccessful in region: {1}, cloud platform: {2}' -f $importImageName, $target.region, $target.platform);
                }
              } catch {
                Write-Output -InputObject ('image: {0}, fetch threw exception in region: {1}, cloud platform: {2}. {3}' -f $importImageName, $target.region, $target.platform, $_.Exception.Message);
              }

              try {
                $azVm = (Get-AzVm `
                  -ResourceGroupName $target.group `
                  -Name $instanceName `
                  -Status `
                  -ErrorAction SilentlyContinue);
                if (($azVm) -and (@($azVm.Statuses | ? { ($_.Code -eq 'OSState/generalized') -or ($_.Code -eq 'PowerState/deallocated') }).Length -eq 2)) {
                  Remove-AzVm `
                    -ResourceGroupName $target.group `
                    -Name $instanceName `
                    -Force;
                  Write-Output -InputObject ('instance: {0}, deletion appears successful in region: {1}, cloud platform: {2}' -f $instanceName, $target.region, $target.platform);
                }
              } catch {
                Write-Output -InputObject ('instance: {0}, fetch/deletion threw exception in region: {1}, cloud platform: {2}. {3}' -f $instanceName, $target.region, $target.platform, $_.Exception.Message);
              }
            }
          }
          Write-Output -InputObject ('end image import: {0} in region: {1}, cloud platform: {2}' -f $importImageName, $target.region, $target.platform);
        } else {
          Write-Output -InputObject ('skipped image import: {0} in region: {1}, cloud platform: {2}' -f $importImageName, $target.region, $target.platform);
          exit 1;
        }
      } catch {
        Write-Output -InputObject ('error: failure in image export: {0}, to region: {1}, in cloud platform: {2}. {3}' -f $exportImageName, $target.region, $target.platform, $_.Exception.Message);
        exit 1;
      }
    }
  }
}