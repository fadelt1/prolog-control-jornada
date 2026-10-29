$Port = 3005
$GinfoBase = "https://ginfo.inovess.com.br"
$PrologBase = "https://prologapp.com/prolog"
$UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
$LogFile = Join-Path $PSScriptRoot "debug-requests.log"

function Write-BridgeLog($msg) {
    $line = "$(Get-Date -Format 'HH:mm:ss') $msg"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

# Si ya hay un listener previo en el puerto 3005, pedirle apagado limpio
try {
    $null = Invoke-RestMethod -Uri "http://localhost:$Port/api/shutdown" -Method Post -TimeoutSec 2 -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 400
} catch {}

Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Web

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13

# ==================== CLIENTE HTTP GINFO ====================
$script:CookieContainer = New-Object System.Net.CookieContainer
$script:Handler = New-Object System.Net.Http.HttpClientHandler
$script:Handler.CookieContainer = $script:CookieContainer
$script:Handler.AllowAutoRedirect = $true
$script:Handler.UseCookies = $true

$script:Client = New-Object System.Net.Http.HttpClient($script:Handler)
$script:Client.DefaultRequestHeaders.Add("User-Agent", $UserAgent)
$script:Client.DefaultRequestHeaders.Add("Accept", "*/*")
$script:Client.Timeout = [TimeSpan]::FromSeconds(25)

$script:Creds = @{
    empresa = "PARAGUAY"
    usuario = "miguel.cabral@fadeltransportes.com.br"
    senha   = "Paraguay12."
}
$script:SessionReady = $false
$script:LastLoginUser = ""

# ==================== CLIENTE Y ESTADO PROLOG ====================
$PrologConfigFile = Join-Path $PSScriptRoot "prolog-config.json"
$loadedCreds = @{
    usuario    = if ($env:PROLOG_USER) { $env:PROLOG_USER } else { "00007097243" }
    senha      = if ($env:PROLOG_PASS) { $env:PROLOG_PASS } else { "04022001" }
    codUnidade = if ($env:PROLOG_UNIT) { [int]$env:PROLOG_UNIT } else { 617 }
}
if (Test-Path $PrologConfigFile) {
    try {
        $rawConfig = [System.IO.File]::ReadAllText($PrologConfigFile, [System.Text.Encoding]::UTF8)
        $cfgJson = $rawConfig | ConvertFrom-Json
        if ($cfgJson.usuario) { $loadedCreds.usuario = [string]$cfgJson.usuario }
        if ($cfgJson.senha)   { $loadedCreds.senha   = [string]$cfgJson.senha }
        if ($cfgJson.codUnidade) { $loadedCreds.codUnidade = [int]$cfgJson.codUnidade }
    } catch {
        Write-BridgeLog "WARN cargando prolog-config.json: $($_.Exception.Message)"
    }
}
$script:PrologCreds = $loadedCreds
$script:PrologToken = ""
$script:PrologUserSelf = $null
$script:PrologLastLoginKey = ""
$script:PrologTokenTime = [DateTime]::MinValue

# Caché en memoria para catálogos de Prolog (evita recargar colaboradores/cargos cada 5s)
$script:PrologCache = @{
    colaboradores = $null
    tiposMarcacoes = $null
    cargosIds = $null
    cachedAt = [DateTime]::MinValue
}

function Connect-PrologSession {
    param($usuario, $senha)

    if (-not $usuario) { $usuario = $script:PrologCreds.usuario }
    if (-not $senha)   { $senha   = $script:PrologCreds.senha }

    Write-BridgeLog "[PROLOG] Autenticando usuario '$usuario' en $PrologBase/api/v3/auth ..."

    $bodyJson = @{
        user = [string]$usuario
        pass = [string]$senha
    } | ConvertTo-Json -Compress

    $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, "$PrologBase/api/v3/auth")
    $req.Content = New-Object System.Net.Http.StringContent($bodyJson, [System.Text.Encoding]::UTF8, "application/json")

    $res = $script:Client.SendAsync($req).GetAwaiter().GetResult()
    $bytes = $res.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $jsonStr = [System.Text.Encoding]::UTF8.GetString($bytes)

    if (-not $res.IsSuccessStatusCode) {
        $script:PrologToken = ""
        throw "Credenciales rechazadas por Prolog (HTTP $([int]$res.StatusCode)): $jsonStr"
    }

    $data = $jsonStr | ConvertFrom-Json
    if (-not $data.token) {
        $script:PrologToken = ""
        throw "Prolog no devolvió un token válido."
    }

    $script:PrologToken = [string]$data.token
    $script:PrologLastLoginKey = "$usuario|$senha"
    $script:PrologTokenTime = [DateTime]::UtcNow

    # Obtener perfil del usuario (/api/v3/users/self)
    try {
        $selfData = Invoke-PrologGet -endpoint "api/v3/users/self"
        $script:PrologUserSelf = $selfData
        if ($selfData.branchOfficeId) {
            $script:PrologCreds.codUnidade = [int]$selfData.branchOfficeId
        }
        Write-BridgeLog "[PROLOG] Sesión activa -> $($selfData.name) | Unidad: $($selfData.branchOfficeName) ($($selfData.branchOfficeId))"
    } catch {
        Write-BridgeLog "[PROLOG] Token obtenido (warn users/self: $($_.Exception.Message))"
    }
}

function Ensure-PrologSession {
    param($usuario, $senha)
    if ($usuario) { $script:PrologCreds.usuario = [string]$usuario }
    if ($senha)   { $script:PrologCreds.senha   = [string]$senha }

    $key = "$($script:PrologCreds.usuario)|$($script:PrologCreds.senha)"
    $ageMinutes = ([DateTime]::UtcNow - $script:PrologTokenTime).TotalMinutes
    if (-not $script:PrologToken -or $script:PrologLastLoginKey -ne $key -or $ageMinutes -gt 45) {
        Connect-PrologSession -usuario $script:PrologCreds.usuario -senha $script:PrologCreds.senha
    }
}

function Invoke-PrologGet {
    param([string]$endpoint)

    $cleanEp = $endpoint.TrimStart('/')
    $url = "$PrologBase/$cleanEp"

    $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $url)
    $req.Headers.Add("Authorization", "Bearer $($script:PrologToken)")
    $req.Headers.Add("Accept", "application/json")

    $res = $script:Client.SendAsync($req).GetAwaiter().GetResult()
    if ([int]$res.StatusCode -eq 401) {
        Write-BridgeLog "[PROLOG] Token expirado (401), re-autenticando..."
        Connect-PrologSession -usuario $script:PrologCreds.usuario -senha $script:PrologCreds.senha
        $req2 = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $url)
        $req2.Headers.Add("Authorization", "Bearer $($script:PrologToken)")
        $req2.Headers.Add("Accept", "application/json")
        $res = $script:Client.SendAsync($req2).GetAwaiter().GetResult()
    }

    $bytes = $res.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $jsonStr = [System.Text.Encoding]::UTF8.GetString($bytes)

    if (-not $res.IsSuccessStatusCode) {
        throw "Error Prolog HTTP $([int]$res.StatusCode) en $cleanEp : $jsonStr"
    }

    return ($jsonStr | ConvertFrom-Json)
}

function Get-PrologCatalogs {
    param([int]$codUnidade, [bool]$force = $false)

    $cacheAgeMin = ([DateTime]::UtcNow - $script:PrologCache.cachedAt).TotalMinutes
    if (-not $force -and $script:PrologCache.colaboradores -and $cacheAgeMin -lt 10) {
        return $script:PrologCache
    }

    Write-BridgeLog "[PROLOG] Cargando catálogos de unidad $codUnidade (filtrando función MOTORISTA)..."
    $colabs = Invoke-PrologGet -endpoint "v2/colaboradores/listagem?codUnidades=$codUnidade&apenasAtivos=true"
    $tipos  = Invoke-PrologGet -endpoint "v2/controle-jornada/tipos-marcacoes/resumidos?codUnidades=$codUnidade"
    $cargos = Invoke-PrologGet -endpoint "v2/cargos/todos/por-unidade?codUnidades=$codUnidade"

    $motoristas = @($colabs | Where-Object { ([string]$_.nomeFuncao).Trim() -match '(?i)MOTORISTA' })

    # Fusionar choferes editados o agregados localmente desde custom-drivers.json
    $CustomDriversFile = Join-Path $PSScriptRoot "custom-drivers.json"
    if (Test-Path $CustomDriversFile) {
        try {
            $rawCustom = [System.IO.File]::ReadAllText($CustomDriversFile, [System.Text.Encoding]::UTF8)
            $customList = if ($rawCustom.Trim()) { @($rawCustom | ConvertFrom-Json) } else { @() }
            $byCpf = @{}
            foreach ($m in $motoristas) {
                $k = ([string]$m.cpf) -replace '^0+', ''
                if ($k) { $byCpf[$k] = $m }
            }
            foreach ($cm in $customList) {
                $ck = ([string]$cm.cpf) -replace '^0+', ''
                if (-not $ck) { continue }
                if ($cm.deleted -eq $true) {
                    $byCpf.Remove($ck)
                } elseif ($byCpf.ContainsKey($ck)) {
                    $existing = $byCpf[$ck]
                    if ($cm.nome) { $existing | Add-Member -NotePropertyName "nome" -NotePropertyValue $cm.nome -Force }
                    if ($cm.nomeEquipe) { $existing | Add-Member -NotePropertyName "nomeEquipe" -NotePropertyValue $cm.nomeEquipe -Force }
                    if ($cm.matriculaAmbev) { $existing | Add-Member -NotePropertyName "matriculaAmbev" -NotePropertyValue $cm.matriculaAmbev -Force }
                    if ($cm.nomeFuncao) { $existing | Add-Member -NotePropertyName "nomeFuncao" -NotePropertyValue $cm.nomeFuncao -Force }
                    if ($null -ne $cm.statusAtivo) { $existing | Add-Member -NotePropertyName "statusAtivo" -NotePropertyValue ([bool]$cm.statusAtivo) -Force }
                    $existing | Add-Member -NotePropertyName "editadoLocal" -NotePropertyValue $true -Force
                } else {
                    $newObj = [PSCustomObject]@{
                        cpf            = ([string]$cm.cpf).PadLeft(11, '0')
                        nome           = ([string]$cm.nome).ToUpper()
                        matriculaAmbev = if ($cm.matriculaAmbev) { [string]$cm.matriculaAmbev } else { "" }
                        nomeUnidade    = "CER_YPE"
                        nomeEquipe     = if ($cm.nomeEquipe) { [string]$cm.nomeEquipe } else { "CER_YPE" }
                        nomeFuncao     = if ($cm.nomeFuncao) { [string]$cm.nomeFuncao } else { "MOTORISTA" }
                        statusAtivo    = if ($null -ne $cm.statusAtivo) { [bool]$cm.statusAtivo } else { $true }
                        creadoLocal    = $true
                    }
                    $byCpf[$ck] = $newObj
                }
            }
            $motoristas = @($byCpf.Values)
        } catch {
            Write-BridgeLog "WARN leyendo custom-drivers.json: $($_.Exception.Message)"
        }
    }

    $cpfSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $nameSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($m in $motoristas) {
        $cCpf = ([string]$m.cpf) -replace '^0+', ''
        if ($cCpf) { [void]$cpfSet.Add($cCpf) }
        $cName = ([string]$m.nome).Trim().ToUpper()
        if ($cName) { [void]$nameSet.Add($cName) }
    }

    $motoristaCargos = @($cargos | Where-Object { ([string]$_.nome) -match '(?i)MOTORISTA' -or ([string]$_.descricao) -match '(?i)MOTORISTA' })
    if ($motoristaCargos.Count -eq 0) { $motoristaCargos = @($cargos) }

    $script:PrologCache.colaboradores = $motoristas
    $script:PrologCache.motoristaCpfs = $cpfSet
    $script:PrologCache.motoristaNames = $nameSet
    $script:PrologCache.tiposMarcacoes = @($tipos)
    $script:PrologCache.cargosIds = @($motoristaCargos | ForEach-Object { $_.codigo })
    $script:PrologCache.cachedAt = [DateTime]::UtcNow

    Write-BridgeLog "[PROLOG] Catálogo listo -> $($motoristas.Count) MOTORISTAS activos (de $(@($colabs).Count) colaboradores totales)"
    return $script:PrologCache
}

function Invoke-PrologSaveDriverDirect {
    param([Parameter(Mandatory=$true)]$driver)
    if (-not $script:PrologToken) {
        return @{ success = $false; error = "Sin sesión activa en Prolog" }
    }
    try {
        $cleanCpf = ([string]$driver.cpf) -replace '^0+', ''
        $colabs = $script:PrologCache.colaboradores
        $orig = $null
        if ($colabs) {
            $orig = $colabs | Where-Object { (([string]$_.cpf) -replace '^0+', '') -eq $cleanCpf } | Select-Object -First 1
        }
        
        $reqObj = @{
            nome = [string]$driver.nome
            cpf = [string]$driver.cpf
            codEmpresa = 1
            codGrupo = "110"
            codUnidade = [int]$script:PrologCreds.codUnidade
            codPermissao = 1
        }
        if ($driver.matriculaAmbev) { $reqObj["matriculaAmbev"] = [int]$driver.matriculaAmbev }
        if ($driver.matriculaTrans) { $reqObj["matriculaTrans"] = [string]$driver.matriculaTrans }

        $method = "POST"
        if ($orig -and $orig.codigo) {
            $method = "PUT"
            $reqObj["codigo"] = [int]$orig.codigo
            $reqObj["codEquipe"] = if ($orig.codEquipe) { [int]$orig.codEquipe } else { 1376 }
            $reqObj["codFuncao"] = if ($orig.codFuncao) { [int]$orig.codFuncao } else { 4634 }
            $reqObj["codSetor"]  = if ($orig.codSetor)  { [int]$orig.codSetor }  else { 1414 }
        }

        $bodyJson = $reqObj | ConvertTo-Json -Compress
        $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::$method, "$PrologBase/v2/colaboradores")
        $req.Headers.Add("Authorization", "Bearer $script:PrologToken")
        $req.Content = New-Object System.Net.Http.StringContent($bodyJson, [System.Text.Encoding]::UTF8, "application/json")
        $res = $script:Client.SendAsync($req).GetAwaiter().GetResult()
        $respBytes = $res.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        $respStr = [System.Text.Encoding]::UTF8.GetString($respBytes)

        if ($res.IsSuccessStatusCode) {
            Write-BridgeLog "[PROLOG DIRECT DB] Chofer '$($driver.nome)' guardado exitosamente en base oficial de Prolog!"
            return @{ success = $true; message = "Guardado directamente en base de datos de Prolog" }
        } else {
            Write-BridgeLog "[PROLOG DIRECT DB] Intento de guardado en base Prolog devolvió HTTP $([int]$res.StatusCode): $respStr"
            return @{ success = $false; statusCode = [int]$res.StatusCode; response = $respStr }
        }
    } catch {
        Write-BridgeLog "[PROLOG DIRECT DB] Excepción: $($_.Exception.Message)"
        return @{ success = $false; error = $_.Exception.Message }
    }
}

function Connect-GinfoSession {
    param($empresa, $usuario, $senha)

    Write-BridgeLog "[GINFO] Autenticando usuario '$usuario' en empresa '$empresa'..."

    try {
        $null = $script:Client.GetAsync("$GinfoBase/").GetAwaiter().GetResult()
    } catch {}

    $formFields = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    $formFields.Add("nomeempresa", $empresa)
    $formFields.Add("empresa", $empresa)
    $formFields.Add("usuario", $usuario)
    $formFields.Add("senha", $senha)

    $reqLogin = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, "$GinfoBase/conecta.php")
    $reqLogin.Headers.Referrer = [Uri]"$GinfoBase/"
    $reqLogin.Content = New-Object System.Net.Http.FormUrlEncodedContent($formFields)

    $loginRes = $script:Client.SendAsync($reqLogin).GetAwaiter().GetResult()
    $loginBytes = $loginRes.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $loginHtml = [System.Text.Encoding]::UTF8.GetString($loginBytes)

    $cookies = $script:CookieContainer.GetCookies([Uri]$GinfoBase)
    $cookieNames = ($cookies | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join "; "
    Write-BridgeLog "[GINFO] conecta.php HTTP $($loginRes.StatusCode) | Cookies: $cookieNames | Len: $($loginHtml.Length)"

    if ($loginHtml -match "(?i)usu.rio ou senha inv.lidos|dados incorretos|empresa inv.lida|n.o encontrado") {
        $script:SessionReady = $false
        throw "Credenciales rechazadas por GINFO (verifique Empresa, Usuario y Contraseña)."
    }

    $dashRes = $script:Client.GetAsync("$GinfoBase/dashboard.php").GetAwaiter().GetResult()
    $dashBytes = $dashRes.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $dashHtml = [System.Text.Encoding]::UTF8.GetString($dashBytes)
    Write-BridgeLog "[GINFO] dashboard.php HTTP $($dashRes.StatusCode) | Len: $($dashHtml.Length)"

    $script:SessionReady = $true
    $script:LastLoginUser = "$empresa|$usuario|$senha"
}

function ConvertTo-IsoDate($dateStr) {
    if (-not $dateStr) { return (Get-Date -Format "yyyy-MM-dd") }
    $s = ([string]$dateStr).Trim()
    if ($s -match "^(\d{2})/(\d{2})/(\d{4})$") {
        return "$($Matches[3])-$($Matches[2])-$($Matches[1])"
    }
    if ($s -match "^(\d{4})-(\d{2})-(\d{2})$") {
        return $s
    }
    return (Get-Date -Format "yyyy-MM-dd")
}

function Get-ChecklistPageHtml {
    param($datainicio, $datafim, $placa, $idmotorista, $pagina)

    $data1 = ConvertTo-IsoDate $datainicio
    $data2 = ConvertTo-IsoDate $datafim
    $pg = [Math]::Max(0, ([int]$pagina) - 1)
    $placaEnc = [uri]::EscapeDataString(([string]$placa).Trim())
    $userEnc  = [uri]::EscapeDataString(([string]$idmotorista).Trim())

    $queryUrl = "$GinfoBase/checklist/relatorio/listadados.php?id_smenu=219&consulta=sim&pg=$pg&tipo=&filial=0&placa=$placaEnc&placacarreta1=&placacarreta2=&data1=$data1&data2=$data2&frota=&fotos=&usuario=$userEnc&empresa=0&regional=0&tiposaida=&mapaexcel=S&equipe=0&projeto=0"

    $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $queryUrl)
    $req.Headers.Referrer = [Uri]"$GinfoBase/dashboard.php?form=checklist/relatorio/index.php&id_menu=18&ds_men=RESUMEN%20DE%20CHECKLIST&ds_mod=FLOTA:%20CHECKLIST&id_smenu=219&tp_smenu=3"
    $req.Headers.Add("X-Requested-With", "XMLHttpRequest")

    $res = $script:Client.SendAsync($req).GetAwaiter().GetResult()
    $bytes = $res.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $html = [System.Text.Encoding]::UTF8.GetString($bytes)

    Write-BridgeLog "[GINFO] listadados.php ($data1 -> $data2, pg=$pg) HTTP $($res.StatusCode) | Len: $($html.Length)"

    return $html
}

$script:GinfoPageCache = @{}

# Limpiar archivos temporales de depuración previos
Get-ChildItem -Path $PSScriptRoot -Filter "debug-*.html" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

$Listener = New-Object System.Net.HttpListener
$Listener.Prefixes.Add("http://localhost:$Port/")
$Listener.Start()

Write-BridgeLog "[PUENTE UNIFICADO PROLOG + GINFO] Activo y escuchando inmediatamente en http://localhost:$Port"

# Precalentar únicamente Prolog (~1.5s) para que la primera carga sea instantánea sin bloquear con GINFO (1.1 MB)
try {
    Ensure-PrologSession -usuario $script:PrologCreds.usuario -senha $script:PrologCreds.senha
    $null = Get-PrologCatalogs -codUnidade $script:PrologCreds.codUnidade -force $true
} catch {
    Write-BridgeLog "WARN Startup Prolog prewarm: $($_.Exception.Message)"
}

function Send-JsonResponse {
    param($Res, [int]$StatusCode, $Object)
    $Json = $Object | ConvertTo-Json -Compress -Depth 8
    $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
    $Res.StatusCode = $StatusCode
    $Res.ContentType = "application/json; charset=utf-8"
    $Res.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $Res.Close()
}

while ($Listener.IsListening) {
    try {
        $Context = $Listener.GetContext()
        $Req = $Context.Request
        $Res = $Context.Response

        $Res.Headers.Add("Access-Control-Allow-Origin", "*")
        $Res.Headers.Add("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        $Res.Headers.Add("Access-Control-Allow-Headers", "Content-Type")

        if ($Req.HttpMethod -eq "OPTIONS") {
            $Res.StatusCode = 204
            $Res.Close()
            continue
        }

        $Path = $Req.Url.AbsolutePath

        if ($Path -eq "/api/shutdown") {
            Write-BridgeLog "Apagando puente por solicitud /api/shutdown"
            $Res.StatusCode = 200
            $Res.Close()
            $Listener.Stop()
            break
        }

        if ($Req.HttpMethod -eq "GET" -and ($Path -eq "/" -or $Path -eq "/index.html")) {
            $HtmlFile = Join-Path $PSScriptRoot "ginfo-control-center.html"
            $Bytes = [System.IO.File]::ReadAllBytes($HtmlFile)
            $Res.ContentType = "text/html; charset=utf-8"
            $Res.OutputStream.Write($Bytes, 0, $Bytes.Length)
            $Res.Close()
            continue
        }

        # ==================== ENDPOINTS PROLOG ====================
        if ($Req.HttpMethod -eq "POST" -and $Path -eq "/api/prolog/login") {
            $Reader = New-Object System.IO.StreamReader($Req.InputStream, [System.Text.Encoding]::UTF8)
            $Payload = $Reader.ReadToEnd() | ConvertFrom-Json

            $script:PrologCreds.usuario = [string]$Payload.usuario
            $script:PrologCreds.senha   = [string]$Payload.senha
            if ($Payload.codUnidade) { $script:PrologCreds.codUnidade = [int]$Payload.codUnidade }

            try {
                Connect-PrologSession -usuario $script:PrologCreds.usuario -senha $script:PrologCreds.senha
                $null = Get-PrologCatalogs -codUnidade $script:PrologCreds.codUnidade -force $true
                Send-JsonResponse -Res $Res -StatusCode 200 -Object @{
                    ok = $true
                    message = "Conectado exitosamente a Prolog"
                    user = $script:PrologUserSelf
                }
            } catch {
                Write-BridgeLog "ERROR PROLOG LOGIN: $($_.Exception.Message)"
                Send-JsonResponse -Res $Res -StatusCode 400 -Object @{
                    ok = $false
                    error = $_.Exception.Message
                }
            }
            continue
        }

        if ($Req.HttpMethod -eq "POST" -and $Path -eq "/api/prolog/sync") {
            $Reader = New-Object System.IO.StreamReader($Req.InputStream, [System.Text.Encoding]::UTF8)
            $Payload = $Reader.ReadToEnd() | ConvertFrom-Json

            try {
                Ensure-PrologSession -usuario $Payload.usuario -senha $Payload.senha
                $codUnidade = if ($Payload.codUnidade) { [int]$Payload.codUnidade } else { [int]$script:PrologCreds.codUnidade }
                $rawIni = if ($Payload.datainicio) { $Payload.datainicio } else { $Payload.dataInicial }
                $rawFim = if ($Payload.datafim)    { $Payload.datafim }    else { $Payload.dataFinal }
                $data1 = ConvertTo-IsoDate $rawIni
                $data2 = ConvertTo-IsoDate $rawFim
                $forceCatalogs = [bool]$Payload.force

                $catalogs = Get-PrologCatalogs -codUnidade $codUnidade -force $forceCatalogs
                $cpfSet = $catalogs.motoristaCpfs
                $nameSet = $catalogs.motoristaNames

                if ($Payload.exactDates) {
                    $queryStart = $data1
                    $queryEnd   = $data2
                } else {
                    # Para que las jornadas abiertas e interjornadas tengan siempre su marcación de inicio/fin sin importar el día,
                    # asegurar una ventana mínima de los últimos 7 días en marcacoes-por-data
                    $minDateStr = (Get-Date).AddDays(-7).ToString("yyyy-MM-dd")
                    $queryStart = if ($data1 -gt $minDateStr) { $minDateStr } else { $data1 }
                    $todayStr   = (Get-Date).ToString("yyyy-MM-dd")
                    $queryEnd   = if ($data2 -lt $todayStr)   { $todayStr }   else { $data2 }
                }

                $epMarcacoes = "v2/controle-jornada/marcacoes-por-data?codUnidade=$codUnidade&dataInicial=$queryStart&dataFinal=$queryEnd"
                if ($Payload.codTipoIntervalo -and $Payload.codTipoIntervalo -ne "TODOS") {
                    $epMarcacoes += "&codTipoIntervalo=$($Payload.codTipoIntervalo)"
                }

                $rawMarcacoes = Invoke-PrologGet -endpoint $epMarcacoes
                $marcacoes = @($rawMarcacoes | Where-Object {
                    $mCpf = ([string]$_.cpfColaborador) -replace '^0+', ''
                    $mName = ([string]$_.nomeColaborador).Trim().ToUpper()
                    ($mCpf -and $cpfSet.Contains($mCpf)) -or ($mName -and $nameSet.Contains($mName))
                })

                # Obtener viajes/jornadas ABIERTAS en tiempo real (sin filtro de fecha) y colaboradores en descanso
                $viagensEmAndamento = @()
                $colaboradoresEmDescanso = @()
                try {
                    if ($catalogs.cargosIds -and $catalogs.cargosIds.Count -gt 0) {
                        $cargoQuery = ($catalogs.cargosIds | ForEach-Object { "codCargos=$_" }) -join "&"
                        $viagensRes = Invoke-PrologGet -endpoint "v2/controle-jornada/acompanhamento-viagens/viagens-em-andamento?codUnidades=$codUnidade&$cargoQuery"
                        if ($viagensRes -and $viagensRes.colaboradoresEmViagem) {
                            $viagensEmAndamento = @($viagensRes.colaboradoresEmViagem | Where-Object {
                                $vCpf = ([string]$_.cpfColaborador) -replace '^0+', ''
                                $vName = ([string]$_.nomeColaborador).Trim().ToUpper()
                                ($vCpf -and $cpfSet.Contains($vCpf)) -or ($vName -and $nameSet.Contains($vName))
                            })
                        }

                        $descansoRes = Invoke-PrologGet -endpoint "v2/controle-jornada/acompanhamento-viagens/colaboradores-em-descanso?codUnidades=$codUnidade&$cargoQuery"
                        if ($descansoRes -and $descansoRes.colaboradoresEmDescanso) {
                            $colaboradoresEmDescanso = @($descansoRes.colaboradoresEmDescanso | Where-Object {
                                $dName = ([string]$_.nomeColaborador).Trim().ToUpper()
                                ($dName -and $nameSet.Contains($dName))
                            })
                        }
                    }
                } catch {
                    Write-BridgeLog "WARN Prolog viagens-em-andamento: $($_.Exception.Message)"
                }

                Write-BridgeLog "[PROLOG] Sync Tiempo Real (Motoristas: $($catalogs.colaboradores.Count)) | Abiertas: $($viagensEmAndamento.Count) | Marcaciones: $($marcacoes.Count)"

                Send-JsonResponse -Res $Res -StatusCode 200 -Object @{
                    ok = $true
                    codUnidade = $codUnidade
                    user = $script:PrologUserSelf
                    marcacoes = $marcacoes
                    colaboradores = @($catalogs.colaboradores)
                    tiposMarcacoes = @($catalogs.tiposMarcacoes)
                    viagensEmAndamento = $viagensEmAndamento
                    colaboradoresEmDescanso = $colaboradoresEmDescanso
                }
            } catch {
                Write-BridgeLog "ERROR PROLOG SYNC: $($_.Exception.Message)"
                Send-JsonResponse -Res $Res -StatusCode 500 -Object @{
                    ok = $false
                    error = $_.Exception.Message
                }
            }
            continue
        }

        if ($Req.HttpMethod -eq "POST" -and $Path -eq "/api/prolog/detail") {
            $Reader = New-Object System.IO.StreamReader($Req.InputStream, [System.Text.Encoding]::UTF8)
            $Payload = $Reader.ReadToEnd() | ConvertFrom-Json

            try {
                Ensure-PrologSession -usuario $Payload.usuario -senha $Payload.senha
                $codUnidade = if ($Payload.codUnidade) { [int]$Payload.codUnidade } else { [int]$script:PrologCreds.codUnidade }
                $cIni = if ($Payload.codInicio) { [int]$Payload.codInicio } else { 0 }
                $cFim = if ($Payload.codFim)    { [int]$Payload.codFim }    else { 0 }
                $cacheKey = "$codUnidade-$cIni-$cFim"

                if (-not $script:PrologGpsCache) { $script:PrologGpsCache = @{} }
                if ($script:PrologGpsCache.ContainsKey($cacheKey)) {
                    $detail = $script:PrologGpsCache[$cacheKey]
                } else {
                    $qs = @("codUnidade=$codUnidade")
                    if ($cIni -gt 0) { $qs += "codInicio=$cIni" }
                    if ($cFim -gt 0) { $qs += "codFim=$cFim" }
                    $epDetail = "v2/controle-jornada/acompanhamento-viagens/marcacao-inicio-fim?" + ($qs -join "&")
                    $detail = Invoke-PrologGet -endpoint $epDetail
                    $script:PrologGpsCache[$cacheKey] = $detail
                }

                Send-JsonResponse -Res $Res -StatusCode 200 -Object @{
                    ok = $true
                    detail = $detail
                }
            } catch {
                Write-BridgeLog "ERROR PROLOG DETAIL: $($_.Exception.Message)"
                Send-JsonResponse -Res $Res -StatusCode 500 -Object @{
                    ok = $false
                    error = $_.Exception.Message
                }
            }
            continue
        }

        if ($Req.HttpMethod -eq "POST" -and $Path -eq "/api/prolog/details-batch") {
            $Reader = New-Object System.IO.StreamReader($Req.InputStream, [System.Text.Encoding]::UTF8)
            $Payload = $Reader.ReadToEnd() | ConvertFrom-Json

            try {
                Ensure-PrologSession -usuario $Payload.usuario -senha $Payload.senha
                $codUnidade = if ($Payload.codUnidade) { [int]$Payload.codUnidade } else { [int]$script:PrologCreds.codUnidade }
                if (-not $script:PrologGpsCache) { $script:PrologGpsCache = @{} }

                $results = @{}
                $items = @($Payload.items)
                foreach ($it in $items) {
                    $cIni = if ($it.codInicio) { [int]$it.codInicio } else { 0 }
                    $cFim = if ($it.codFim)    { [int]$it.codFim }    else { 0 }
                    if ($cIni -le 0 -and $cFim -le 0) { continue }

                    $key = "$cIni-$cFim"
                    $cacheKey = "$codUnidade-$cIni-$cFim"
                    if ($script:PrologGpsCache.ContainsKey($cacheKey)) {
                        $results[$key] = $script:PrologGpsCache[$cacheKey]
                    } else {
                        try {
                            $qs = @("codUnidade=$codUnidade")
                            if ($cIni -gt 0) { $qs += "codInicio=$cIni" }
                            if ($cFim -gt 0) { $qs += "codFim=$cFim" }
                            $epDetail = "v2/controle-jornada/acompanhamento-viagens/marcacao-inicio-fim?" + ($qs -join "&")
                            $det = Invoke-PrologGet -endpoint $epDetail
                            $script:PrologGpsCache[$cacheKey] = $det
                            $results[$key] = $det
                        } catch {
                            Write-BridgeLog "WARN batch GPS ($key): $($_.Exception.Message)"
                        }
                    }
                }

                Send-JsonResponse -Res $Res -StatusCode 200 -Object @{
                    ok = $true
                    details = $results
                }
            } catch {
                Send-JsonResponse -Res $Res -StatusCode 500 -Object @{
                    ok = $false
                    error = $_.Exception.Message
                }
            }
            continue
        }

        if ($Path -eq "/api/prolog/geofences") {
            $GeoFile = Join-Path $PSScriptRoot "geofences.json"
            if ($Req.HttpMethod -eq "GET") {
                if (Test-Path $GeoFile) {
                    $raw = [System.IO.File]::ReadAllText($GeoFile, [System.Text.Encoding]::UTF8)
                    $parsed = if ($raw.Trim()) { $raw | ConvertFrom-Json } else { @() }
                    Send-JsonResponse -Res $Res -StatusCode 200 -Object @{ ok = $true; geofences = @($parsed) }
                } else {
                    Send-JsonResponse -Res $Res -StatusCode 200 -Object @{ ok = $true; geofences = @() }
                }
                continue
            }
            if ($Req.HttpMethod -eq "POST") {
                $Reader = New-Object System.IO.StreamReader($Req.InputStream, [System.Text.Encoding]::UTF8)
                $BodyStr = $Reader.ReadToEnd()
                $Payload = $BodyStr | ConvertFrom-Json
                $geoJson = @($Payload.geofences) | ConvertTo-Json -Depth 8
                [System.IO.File]::WriteAllText($GeoFile, $geoJson, [System.Text.Encoding]::UTF8)
                Send-JsonResponse -Res $Res -StatusCode 200 -Object @{ ok = $true }
                continue
            }
        }

        if ($Path -eq "/api/prolog/custom-drivers") {
            $CustomDriversFile = Join-Path $PSScriptRoot "custom-drivers.json"
            if ($Req.HttpMethod -eq "GET") {
                if (Test-Path $CustomDriversFile) {
                    $raw = [System.IO.File]::ReadAllText($CustomDriversFile, [System.Text.Encoding]::UTF8)
                    $parsed = if ($raw.Trim()) { $raw | ConvertFrom-Json } else { @() }
                    Send-JsonResponse -Res $Res -StatusCode 200 -Object @{ ok = $true; customDrivers = @($parsed) }
                } else {
                    Send-JsonResponse -Res $Res -StatusCode 200 -Object @{ ok = $true; customDrivers = @() }
                }
                continue
            }
            if ($Req.HttpMethod -eq "POST") {
                $Reader = New-Object System.IO.StreamReader($Req.InputStream, [System.Text.Encoding]::UTF8)
                $BodyStr = $Reader.ReadToEnd()
                $Payload = $BodyStr | ConvertFrom-Json
                $drvJson = @($Payload.customDrivers) | ConvertTo-Json -Depth 8
                [System.IO.File]::WriteAllText($CustomDriversFile, $drvJson, [System.Text.Encoding]::UTF8)

                # Intentar guardado directo en la base de datos de Prolog si viene indicado
                $directResults = @()
                if ($Payload.driverToSave) {
                    $resDirect = Invoke-PrologSaveDriverDirect -driver $Payload.driverToSave
                    $directResults += $resDirect
                }

                $script:PrologCache.cachedAt = [DateTime]::MinValue
                $catalogs = Get-PrologCatalogs -codUnidade $script:PrologCreds.codUnidade -force $true
                Send-JsonResponse -Res $Res -StatusCode 200 -Object @{
                    ok = $true
                    colaboradores = @($catalogs.colaboradores)
                    directResults = $directResults
                }
                continue
            }
        }

        # ==================== ENDPOINTS GINFO ====================
        if ($Req.HttpMethod -eq "POST" -and $Path -eq "/api/login") {
            $Reader = New-Object System.IO.StreamReader($Req.InputStream, [System.Text.Encoding]::UTF8)
            $BodyStr = $Reader.ReadToEnd()
            $Payload = $BodyStr | ConvertFrom-Json

            $script:Creds.empresa = if ($Payload.empresa) { $Payload.empresa } else { "PARAGUAY" }
            $script:Creds.usuario = $Payload.usuario
            $script:Creds.senha   = $Payload.senha

            try {
                Connect-GinfoSession -empresa $script:Creds.empresa -usuario $script:Creds.usuario -senha $script:Creds.senha
                Send-JsonResponse -Res $Res -StatusCode 200 -Object @{ ok = $true; message = "Conectado exitosamente a GINFO" }
            } catch {
                Write-BridgeLog "ERROR LOGIN: $($_.Exception.Message)"
                Send-JsonResponse -Res $Res -StatusCode 400 -Object @{ ok = $false; error = $_.Exception.Message }
            }
            continue
        }

        if ($Req.HttpMethod -eq "POST" -and $Path -eq "/api/page") {
            $Reader = New-Object System.IO.StreamReader($Req.InputStream, [System.Text.Encoding]::UTF8)
            $BodyStr = $Reader.ReadToEnd()
            $Payload = $BodyStr | ConvertFrom-Json

            try {
                if ($Payload.usuario -and $Payload.senha) {
                    $script:Creds.empresa = if ($Payload.empresa) { $Payload.empresa } else { "PARAGUAY" }
                    $script:Creds.usuario = $Payload.usuario
                    $script:Creds.senha   = $Payload.senha
                }

                $credKey = "$($script:Creds.empresa)|$($script:Creds.usuario)|$($script:Creds.senha)"
                $cacheKey = "$($Payload.datainicio)|$($Payload.datafim)|$($Payload.placa)|$($Payload.idmotorista)|$($Payload.pagina)"
                $cachedEntry = $script:GinfoPageCache[$cacheKey]

                if (-not $Payload.force -and $cachedEntry -and (([DateTime]::UtcNow - $cachedEntry.time).TotalSeconds -lt 25)) {
                    Send-JsonResponse -Res $Res -StatusCode 200 -Object @{ ok = $true; html = $cachedEntry.html; cached = $true }
                    continue
                }

                if (-not $script:SessionReady -or $script:LastLoginUser -ne $credKey) {
                    Connect-GinfoSession -empresa $script:Creds.empresa -usuario $script:Creds.usuario -senha $script:Creds.senha
                }

                $HtmlTable = Get-ChecklistPageHtml `
                    -datainicio $Payload.datainicio `
                    -datafim $Payload.datafim `
                    -placa ([string]$Payload.placa) `
                    -idmotorista ([string]$Payload.idmotorista) `
                    -pagina ([int]$Payload.pagina)

                if (-not $HtmlTable -or $HtmlTable.Length -lt 200) {
                    Connect-GinfoSession -empresa $script:Creds.empresa -usuario $script:Creds.usuario -senha $script:Creds.senha
                    $HtmlTable = Get-ChecklistPageHtml `
                        -datainicio $Payload.datainicio `
                        -datafim $Payload.datafim `
                        -placa ([string]$Payload.placa) `
                        -idmotorista ([string]$Payload.idmotorista) `
                        -pagina ([int]$Payload.pagina)
                }

                $script:GinfoPageCache[$cacheKey] = @{
                    html = $HtmlTable
                    time = [DateTime]::UtcNow
                }

                Send-JsonResponse -Res $Res -StatusCode 200 -Object @{ ok = $true; html = $HtmlTable }
            } catch {
                Write-BridgeLog "ERROR PAGE: $($_.Exception.Message)"
                Send-JsonResponse -Res $Res -StatusCode 500 -Object @{ ok = $false; error = $_.Exception.Message }
            }
            continue
        }

        $Res.StatusCode = 404
        $Res.Close()
    } catch {
        try { $Context.Response.Close() } catch {}
    }
}
