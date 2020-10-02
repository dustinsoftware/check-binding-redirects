param($validateBindingsForSolution, $configName, $binPath, [switch] $validateBindings, $addBindingFor)
$ErrorActionPreference = "Stop"

if (!($validateBindingsForSolution -eq $null) -or $validateBindings -or !($addBindingFor -eq $null)) {
    # No-op
} else {
    throw "One of -validateBindingsForSolution, -validateBindings, or -addBindingFor must be specified"
}

function LoadDllVersions {
    param($binPath)
    $dlls = Get-ChildItem $binPath -Filter "*.dll"

    return Get-ChildItem $binPath -Filter *.dll  | ForEach-Object `
    {
        $dllName = $_
        try {
            return [PSCustomObject]@{
                Name = $_.Name
                FileVersion = $_.VersionInfo.FileVersion
                AssemblyVersion = ([Reflection.AssemblyName]::GetAssemblyName($_.FullName).Version)
                PublicKeyToken = ([Reflection.AssemblyName]::GetAssemblyName($_.FullName)).ToString() | Select-String "PublicKeyToken=(\w+)" | % { $_.matches.groups[1].value }
                AssemblyName = ([Reflection.AssemblyName]::GetAssemblyName($_.FullName).Name)
            }
        } catch {
            # Skip kafka and related native dll's
            if ($_.ToString() -match "The module was expected to contain an assembly manifest") {
                Write-Host "Presumed native DLL, skipping load for $dllName"
            } else {
                throw $_
            }
        }

    }
}


function GetBindingsFromConfig {
    param($configName)
    return Get-ChildItem $configName | % { ([xml] (Get-Content $_)).configuration.runtime.assemblyBinding.dependentAssembly }
}

function ValidateBindings {
    param($configName, $binPath)
    $dllVersions = LoadDllVersions $binPath

    $hasError = $false
    GetBindingsFromConfig $configName | % {
        $assemblyName = $_.assemblyIdentity.Name
        $newVersion = $_.bindingRedirect.newVersion
        $publicKeyToken = $_.assemblyIdentity.publicKeyToken
        Write-Host "Found redirects for $assemblyName version $newVersion"
        $matchedDll = $dllVersions | Where-Object { $_.Name -eq "$assemblyName.dll"}
        if ($matchedDll -eq $null) {
            Write-Host -ForegroundColor Yellow "Did not find $assemblyName.dll. Consider removing this redirect."
        }
        elseif (!($matchedDll.AssemblyVersion -eq "$newVersion")) {
            Write-Host -ForegroundColor Red "DLL version does not match for $assemblyName! Requested version $newVersion, but found $($matchedDll.AssemblyVersion)"
            $hasError = $true
        }
        elseif (!($matchedDll.PublicKeyToken -eq "null") -and !($matchedDll.PublicKeyToken -eq "$publicKeyToken")) {
            Write-Host -ForegroundColor Red "DLL public key token does not match for $assemblyName! Requested version $publicKeyToken, but found $($matchedDll.PublicKeyToken)"
            $hasError = $true
        }
    }

    if ($hasError) {
        throw "Cannot continue"
    }
}

if ($validateBindings) {
    if ($configName -eq $null) {
        throw "No configName specified"
    }
    if ($binPath -eq $null) {
        throw "No binPath specified"
    }
    ValidateBindings $configName $binPath
}

if ($addBindingFor) {
    $xml = [xml] (Get-Content $configName)
    $resolvedDll = LoadDllVersions $binPath | Where-Object { $_.Name -eq $addBindingFor }

    if ($resolvedDll -eq $null) {
        throw "Could not find $addBindingFor, make sure .dll is used as an extension"
    }

    $dependentAssembly = $xml.CreateElement('dependentAssembly', $xml.NamespaceURI)
    $assemblyIdentity = $xml.CreateElement('assemblyIdentity')
    $assemblyIdentity.SetAttribute("name", $resolvedDll.AssemblyName)
    $assemblyIdentity.SetAttribute("publicKeyToken", $resolvedDll.PublicKeyToken)
    $assemblyIdentity.SetAttribute("culture", "neutral")
    $dependentAssembly.AppendChild($assemblyIdentity)

    $bindingRedirect = $xml.CreateElement("bindingRedirect")
    $bindingRedirect.SetAttribute("oldVersion", "0.0.0.0-$($resolvedDll.AssemblyVersion)")
    $bindingRedirect.SetAttribute("newVersion", $resolvedDll.AssemblyVersion)
    $dependentAssembly.AppendChild($bindingRedirect)

    $xml.configuration.runtime.assemblyBinding.AppendChild($dependentAssembly)

    $xml.Save((Resolve-Path $configName))

    # hack, because xmlns gets added automatically :(
    $config = Get-Content $configName
    Set-Content $configName ($config -replace "<dependentAssembly xmlns="""">", "<dependentAssembly>")
}

if ($validateBindingsForSolution) {
    # console projects
    $rootPath = Resolve-Path $validateBindingsForSolution

    function ProcessConfig {
        param($configName)

        pushd $rootPath
        $configs = Get-ChildItem $configName -Recurse
        $configs | % {
            if ($_.Directory.ToString().Contains("Views")) {
                Write-Host "Skipping $_"
                return
            }
            pushd $_.Directory;
            Write-Output $_;
            if (Test-Path "appsettings.json") {
                return
            }
            if (Test-Path "bin\debug\net48") {
                $binPath = "bin\debug\net48"
            } elseif (Test-Path "bin\debug"){
                $binPath = "bin\debug"
            } elseif (Test-Path "bin"){
                $binPath = "bin"
            } else {
                $binPath = ""
            }

            ValidateBindings -configName .\$configName -binPath .\$binPath -validateBindings;
            popd
        }
        popd
    }

    ProcessConfig "app.config"
    ProcessConfig "web.config"
}
