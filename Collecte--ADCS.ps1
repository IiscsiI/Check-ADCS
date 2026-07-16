<#
.SYNOPSIS
    Collecteur ADCS en lecture seule — exporte l'etat de la CA vers un fichier JSON
    destine au visualiseur HTML autonome (visualiseur-adcs.html).

.DESCRIPTION
    Interroge la base de donnees d'une autorite de certification ADCS via l'interface
    COM native ICertView (CertificateAuthority.View), en RPC distant, SANS AUCUNE
    ECRITURE sur la CA. Aucun module externe requis (pas de PSPKI).

    Donnees collectees :
      - Certificats emis et revoques (disposition 20 / 21)
      - Requetes en attente (disposition 9)
      - Requetes en echec ou refusees (disposition 30 / 31)
      - Modeles de certificats publies dans l'AD (mappage OID -> nom d'affichage)
      - Sante des CRL (thisUpdate / nextUpdate, lues depuis le partage CertEnroll
        ou une URL CDP, via un lecteur ASN.1 integre — jamais via 'certutil -crl',
        qui REPUBLIERAIT une CRL)

    Droits requis : permission "Read" sur la CA (ou role Auditor si la separation
    des roles est activee). Ne jamais utiliser un compte administrateur de la CA.

.PARAMETER Config
    Configuration de la CA au format "SERVEUR\Nom de la CA".
    Si omis : auto-detection de la premiere CA d'entreprise publiee dans l'AD.

.PARAMETER Depuis
    Optionnel. Ne collecte que les requetes soumises apres cette date
    (restriction cote serveur sur Request.SubmittedWhen). Recommande sur les
    bases volumineuses.

.PARAMETER Sortie
    Dossier de sortie. Defaut : dossier courant. Produit "adcs-data.json".

.PARAMETER CheminCRL
    Optionnel. Chemin(s) UNC, local(aux) ou URL http(s) vers les fichiers CRL.
    Defaut : \\<serveur CA>\CertEnroll\*.crl

.PARAMETER Html
    Optionnel. Chemin vers visualiseur-adcs.html : genere en plus un fichier
    HTML auto-porteur (JSON embarque) "visualiseur-adcs-autoporteur.html".

.PARAMETER AlerteCRLHeures
    Marge (en heures) avant nextUpdate en-deca de laquelle la CRL est signalee
    "a surveiller". Defaut : 24.

.EXAMPLE
    .\Collecte-ADCS.ps1
    Auto-detection de la CA, export adcs-data.json dans le dossier courant.

.EXAMPLE
    .\Collecte-ADCS.ps1 -Config "SRV-PKI01\CA-Collectivite" -Depuis (Get-Date).AddYears(-3) -Html .\visualiseur-adcs.html
    Collecte limitee aux 3 dernieres annees et generation du HTML auto-porteur.

.NOTES
    Lecture seule stricte. Aucune commande de modification n'est emise vers la CA.
    Compatibilite : Windows PowerShell 5.1 et PowerShell 7+.
      - PowerShell 7+ recommande sur les bases volumineuses : serialisation JSON
        native rapide (~50 000 certificats en 1 a 2 secondes).
      - Sous 5.1, le script utilise automatiquement JavaScriptSerializer
        (.NET Framework) au lieu de ConvertTo-Json, dont les performances
        s'effondrent au-dela de quelques milliers d'objets.
    Planification recommandee : tache planifiee quotidienne avec un compte dedie
    en lecture seule, sortie sur un partage accessible a la DSI.
#>
[CmdletBinding()]
param(
    [string]$Config,
    [datetime]$Depuis,
    [string]$Sortie = ".",
    [string[]]$CheminCRL,
    [string]$Html,
    [int]$AlerteCRLHeures = 24
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$chrono = [System.Diagnostics.Stopwatch]::StartNew()

# ---------------------------------------------------------------------------
# Resolution des chemins en absolu.
# Les API .NET ([System.IO.File]::WriteAllText, etc.) resolvent les chemins
# relatifs contre le repertoire du PROCESSUS (Environment.CurrentDirectory),
# qui n'est pas synchronise avec le $PWD de la session PowerShell. Tout chemin
# fourni en parametre est donc normalise ici contre $PWD avant usage.
# ---------------------------------------------------------------------------
function Resolve-CheminAbsolu {
    param([string]$Chemin)
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Chemin)
}
$Sortie = Resolve-CheminAbsolu $Sortie
if ($Html) { $Html = Resolve-CheminAbsolu $Html }

# ---------------------------------------------------------------------------
# Constantes ICertView / dispositions
# ---------------------------------------------------------------------------
$CVR_SEEK_GE   = 0x10
$DISP_PENDING  = 9
$DISP_ISSUED   = 20
$DISP_REVOKED  = 21
$DISP_ERROR    = 30
$DISP_DENIED   = 31

$RaisonsRevocation = @{
    0 = 'Non specifiee'
    1 = 'Compromission de cle'
    2 = 'Compromission de la CA'
    3 = "Changement d'affiliation"
    4 = 'Remplace'
    5 = "Cessation d'activite"
    6 = 'Suspension (certificateHold)'
}

# ---------------------------------------------------------------------------
# Serialisation JSON performante selon la version de PowerShell
#   - PS 7+  : ConvertTo-Json natif (moteur reecrit, ~50 000 objets en 1-2 s)
#   - PS 5.1 : JavaScriptSerializer (.NET Framework), 20 a 50 fois plus rapide
#              que le ConvertTo-Json de 5.1 sur les gros volumes.
#   Les structures du script (OrderedDictionary + ArrayList, dates deja en
#   chaines ISO 8601) sont serialisables a l'identique par les deux moteurs.
# ---------------------------------------------------------------------------
function ConvertTo-JsonRapide {
    param([Parameter(Mandatory)]$Objet)
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        return (ConvertTo-Json -InputObject $Objet -Depth 6 -Compress)
    }
    try {
        Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
        $serialiseur = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $serialiseur.MaxJsonLength = [int32]::MaxValue
        $serialiseur.RecursionLimit = 64
        return $serialiseur.Serialize($Objet)
    } catch {
        Write-Warning "JavaScriptSerializer indisponible ($($_.Exception.Message)) : repli sur ConvertTo-Json, nettement plus lent sous PowerShell 5.1."
        return (ConvertTo-Json -InputObject $Objet -Depth 6 -Compress)
    }
}

# ---------------------------------------------------------------------------
# Auto-detection des CA d'entreprise publiees dans l'AD
# ---------------------------------------------------------------------------
function Get-CAConfigurations {
    $rootDSE = [ADSI]'LDAP://RootDSE'
    $cfgNC = $rootDSE.Properties['configurationNamingContext'].Value
    $conteneur = [ADSI]("LDAP://CN=Enrollment Services,CN=Public Key Services,CN=Services," + $cfgNC)
    $resultats = @()
    foreach ($enfant in $conteneur.Children) {
        $nom = $enfant.Properties['cn'].Value
        $srv = $enfant.Properties['dNSHostName'].Value
        if ($nom -and $srv) {
            $resultats += [pscustomobject]@{ Nom = $nom; Serveur = $srv; Config = "$srv\$nom" }
        }
    }
    return $resultats
}

# ---------------------------------------------------------------------------
# Mappage des modeles de certificats (OID / nom v1 -> nom d'affichage)
# ---------------------------------------------------------------------------
function Get-TemplateMap {
    $map = @{}
    $liste = New-Object System.Collections.ArrayList
    try {
        $rootDSE = [ADSI]'LDAP://RootDSE'
        $cfgNC = $rootDSE.Properties['configurationNamingContext'].Value
        $conteneur = [ADSI]("LDAP://CN=Certificate Templates,CN=Public Key Services,CN=Services," + $cfgNC)
        foreach ($t in $conteneur.Children) {
            $nom = $t.Properties['cn'].Value
            $affichage = $t.Properties['displayName'].Value
            $oid = $t.Properties['msPKI-Cert-Template-OID'].Value
            $entree = [ordered]@{ nom = "$nom"; affichage = "$affichage"; oid = "$oid" }
            [void]$liste.Add($entree)
            if ($oid) { $map["$oid"] = $entree }
            if ($nom) { $map["$nom"] = $entree }   # modeles v1 : references par nom
        }
    } catch {
        Write-Warning "Lecture des modeles dans l'AD impossible : $($_.Exception.Message)"
    }
    return @{ Map = $map; Liste = $liste }
}

# ---------------------------------------------------------------------------
# Lecteur ASN.1 minimal : extraction thisUpdate / nextUpdate d'une CRL X.509
# (lecture pure d'un fichier, aucune interaction avec la CA)
# ---------------------------------------------------------------------------
function Read-Asn1Element {
    param([byte[]]$Octets, [int]$Position)
    $tag = $Octets[$Position]; $p = $Position + 1
    $longueur = [int]$Octets[$p]; $p++
    if ($longueur -band 0x80) {
        $n = $longueur -band 0x7F
        $longueur = 0
        for ($i = 0; $i -lt $n; $i++) { $longueur = ($longueur * 256) + [int]$Octets[$p]; $p++ }
    }
    return [pscustomobject]@{ Tag = $tag; Longueur = $longueur; Contenu = $p; Fin = $p + $longueur }
}

function Convert-Asn1Time {
    param([byte[]]$Octets, $Element)
    $texte = [System.Text.Encoding]::ASCII.GetString($Octets, $Element.Contenu, $Element.Longueur)
    $texte = $texte.TrimEnd('Z')
    if ($Element.Tag -eq 0x17) {        # UTCTime : YYMMDDHHMMSS
        $dt = [datetime]::ParseExact($texte, 'yyMMddHHmmss', $null)
    } elseif ($Element.Tag -eq 0x18) {  # GeneralizedTime : YYYYMMDDHHMMSS
        $dt = [datetime]::ParseExact($texte, 'yyyyMMddHHmmss', $null)
    } else { return $null }
    return [datetime]::SpecifyKind($dt, [System.DateTimeKind]::Utc).ToLocalTime()
}

function Get-CRLDates {
    param([byte[]]$Octets)
    # PEM -> DER si necessaire
    if ($Octets.Length -gt 10) {
        $entete = [System.Text.Encoding]::ASCII.GetString($Octets, 0, [Math]::Min(60, $Octets.Length))
        if ($entete -match '-----BEGIN') {
            $texte = [System.Text.Encoding]::ASCII.GetString($Octets)
            $b64 = ($texte -replace '-----[^-]+-----', '') -replace '\s', ''
            $Octets = [Convert]::FromBase64String($b64)
        }
    }
    $externe = Read-Asn1Element $Octets 0                       # CertificateList SEQUENCE
    $tbs = Read-Asn1Element $Octets $externe.Contenu            # tbsCertList SEQUENCE
    $p = $tbs.Contenu
    $e = Read-Asn1Element $Octets $p
    if ($e.Tag -eq 0x02) { $p = $e.Fin; $e = Read-Asn1Element $Octets $p }   # version (optionnel)
    $p = $e.Fin                                                 # signature AlgorithmIdentifier
    $e = Read-Asn1Element $Octets $p                            # issuer Name
    $p = $e.Fin
    $e = Read-Asn1Element $Octets $p                            # thisUpdate
    $thisUpdate = Convert-Asn1Time $Octets $e
    $p = $e.Fin
    $nextUpdate = $null
    if ($p -lt $tbs.Fin) {
        $e = Read-Asn1Element $Octets $p
        if ($e.Tag -in 0x17, 0x18) { $nextUpdate = Convert-Asn1Time $Octets $e }
    }
    return @{ thisUpdate = $thisUpdate; nextUpdate = $nextUpdate }
}

function Get-OctetsCRL {
    param([string]$Chemin)
    if ($Chemin -match '^https?://') {
        $reponse = Invoke-WebRequest -Uri $Chemin -UseBasicParsing -TimeoutSec 30
        return [byte[]]$reponse.Content
    }
    return [System.IO.File]::ReadAllBytes((Resolve-CheminAbsolu $Chemin))
}

# ---------------------------------------------------------------------------
# 1. Resolution de la CA cible
# ---------------------------------------------------------------------------
if (-not $Config) {
    Write-Host 'Auto-detection des CA publiees dans Active Directory...'
    $cas = @(Get-CAConfigurations)
    if ($cas.Count -eq 0) { throw "Aucune CA d'entreprise trouvee dans l'AD. Precisez -Config 'SERVEUR\Nom CA'." }
    if ($cas.Count -gt 1) {
        Write-Warning ("Plusieurs CA detectees : " + (($cas | ForEach-Object { $_.Config }) -join ' | '))
        Write-Warning ("Collecte sur la premiere : " + $cas[0].Config + " (utilisez -Config pour cibler une autre CA)")
    }
    $Config = $cas[0].Config
}
$serveurCA = $Config.Split('\')[0]
$nomCA = $Config.Split('\')[-1]
Write-Host "CA cible : $Config"

# ---------------------------------------------------------------------------
# 2. Mappage des modeles
# ---------------------------------------------------------------------------
Write-Host 'Lecture des modeles de certificats dans l''AD...'
$tpl = Get-TemplateMap
$templateMap = $tpl.Map

function Resolve-Template {
    param([string]$Brut)
    if ([string]::IsNullOrWhiteSpace($Brut)) { return [ordered]@{ nom = ''; affichage = '(aucun)'; oid = '' } }
    if ($templateMap.ContainsKey($Brut)) {
        $t = $templateMap[$Brut]
        return [ordered]@{ nom = $t.nom; affichage = $t.affichage; oid = $t.oid }
    }
    return [ordered]@{ nom = $Brut; affichage = $Brut; oid = $Brut }
}

# ---------------------------------------------------------------------------
# 3. Interrogation de la base CA (ICertView — lecture seule)
# ---------------------------------------------------------------------------
Write-Host 'Ouverture de la vue sur la base de la CA (lecture seule, RPC)...'
$vue = New-Object -ComObject CertificateAuthority.View
$vue.OpenConnection($Config)

$colonnes = @(
    'Request.RequestID', 'Request.RequesterName', 'Request.SubmittedWhen',
    'Request.Disposition', 'Request.DispositionMessage',
    'Request.RevokedWhen', 'Request.RevokedReason',
    'CommonName', 'NotBefore', 'NotAfter', 'SerialNumber', 'CertificateTemplate'
)
$vue.SetResultColumnCount($colonnes.Count)
foreach ($c in $colonnes) {
    $vue.SetResultColumn($vue.GetColumnIndex($false, $c))
}
if ($PSBoundParameters.ContainsKey('Depuis')) {
    Write-Host ("Restriction : requetes soumises depuis le " + $Depuis.ToString('dd/MM/yyyy'))
    $idxSoumis = $vue.GetColumnIndex($false, 'Request.SubmittedWhen')
    $vue.SetRestriction($idxSoumis, $CVR_SEEK_GE, 0, $Depuis)
}

$lignes = $vue.OpenView()
$certificats = New-Object System.Collections.ArrayList
$enAttente   = New-Object System.Collections.ArrayList
$echecs      = New-Object System.Collections.ArrayList
$compteur = 0

while ($lignes.Next() -ne -1) {
    $compteur++
    if ($compteur % 5000 -eq 0) { Write-Host "  $compteur lignes lues..." }
    # L'enumerateur de colonnes suit l'ordre des colonnes de resultat definies
    # plus haut : mappage par position, sans appel COM GetName() par cellule.
    $valeurs = @{}
    $cols = $lignes.EnumCertViewColumn()
    $k = 0
    while ($cols.Next() -ne -1 -and $k -lt $colonnes.Count) {
        try { $valeurs[$colonnes[$k]] = $cols.GetValue(1) } catch { $valeurs[$colonnes[$k]] = $null }
        $k++
    }
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($cols) | Out-Null

    $disposition = [int]$valeurs['Request.Disposition']
    $modele = Resolve-Template $valeurs['CertificateTemplate']

    switch ($disposition) {
        { $_ -in $DISP_ISSUED, $DISP_REVOKED } {
            $obj = [ordered]@{
                id        = [int]$valeurs['Request.RequestID']
                cn        = "$($valeurs['CommonName'])"
                demandeur = "$($valeurs['Request.RequesterName'])"
                template  = $modele
                soumisLe  = if ($valeurs['Request.SubmittedWhen']) { ([datetime]$valeurs['Request.SubmittedWhen']).ToString('s') } else { $null }
                notBefore = if ($valeurs['NotBefore']) { ([datetime]$valeurs['NotBefore']).ToString('s') } else { $null }
                notAfter  = if ($valeurs['NotAfter'])  { ([datetime]$valeurs['NotAfter']).ToString('s') }  else { $null }
                serie     = "$($valeurs['SerialNumber'])"
                revoque   = ($disposition -eq $DISP_REVOKED)
                revoqueLe = $null
                raisonRevocation = $null
            }
            if ($disposition -eq $DISP_REVOKED) {
                if ($valeurs['Request.RevokedWhen']) { $obj.revoqueLe = ([datetime]$valeurs['Request.RevokedWhen']).ToString('s') }
                $codeRaison = if ($null -ne $valeurs['Request.RevokedReason']) { [int]$valeurs['Request.RevokedReason'] } else { 0 }
                $obj.raisonRevocation = if ($RaisonsRevocation.ContainsKey($codeRaison)) { $RaisonsRevocation[$codeRaison] } else { "Code $codeRaison" }
            }
            [void]$certificats.Add($obj)
        }
        $DISP_PENDING {
            [void]$enAttente.Add([ordered]@{
                id        = [int]$valeurs['Request.RequestID']
                demandeur = "$($valeurs['Request.RequesterName'])"
                cn        = "$($valeurs['CommonName'])"
                template  = $modele
                soumisLe  = if ($valeurs['Request.SubmittedWhen']) { ([datetime]$valeurs['Request.SubmittedWhen']).ToString('s') } else { $null }
            })
        }
        { $_ -in $DISP_ERROR, $DISP_DENIED } {
            [void]$echecs.Add([ordered]@{
                id          = [int]$valeurs['Request.RequestID']
                demandeur   = "$($valeurs['Request.RequesterName'])"
                cn          = "$($valeurs['CommonName'])"
                template    = $modele
                soumisLe    = if ($valeurs['Request.SubmittedWhen']) { ([datetime]$valeurs['Request.SubmittedWhen']).ToString('s') } else { $null }
                disposition = if ($disposition -eq $DISP_DENIED) { 'Refusee' } else { 'Erreur' }
                message     = "$($valeurs['Request.DispositionMessage'])".Trim()
            })
        }
    }
}
Write-Host "  $compteur lignes traitees : $($certificats.Count) certificats, $($enAttente.Count) en attente, $($echecs.Count) echecs."

# ---------------------------------------------------------------------------
# 4. Sante des CRL (lecture de fichiers uniquement)
# ---------------------------------------------------------------------------
$crls = New-Object System.Collections.ArrayList
$sourcesCRL = @()
if ($CheminCRL) {
    $sourcesCRL = $CheminCRL
} else {
    $partage = "\\$serveurCA\CertEnroll"
    Write-Host "Recherche des CRL sur $partage ..."
    try {
        $sourcesCRL = @(Get-ChildItem -Path $partage -Filter '*.crl' -ErrorAction Stop | ForEach-Object { $_.FullName })
    } catch {
        Write-Warning "Partage CertEnroll inaccessible ($($_.Exception.Message)). Utilisez -CheminCRL pour indiquer les CRL."
    }
}
foreach ($src in $sourcesCRL) {
    try {
        $octets = Get-OctetsCRL -Chemin $src
        $dates = Get-CRLDates -Octets $octets
        $enRetard = $false; $aSurveiller = $false
        if ($dates.nextUpdate) {
            $enRetard = ($dates.nextUpdate -lt (Get-Date))
            $aSurveiller = (-not $enRetard) -and ($dates.nextUpdate -lt (Get-Date).AddHours($AlerteCRLHeures))
        }
        [void]$crls.Add([ordered]@{
            source      = $src
            fichier     = [System.IO.Path]::GetFileName($src)
            delta       = ([System.IO.Path]::GetFileName($src) -like '*+*')
            thisUpdate  = if ($dates.thisUpdate) { $dates.thisUpdate.ToString('s') } else { $null }
            nextUpdate  = if ($dates.nextUpdate) { $dates.nextUpdate.ToString('s') } else { $null }
            enRetard    = $enRetard
            aSurveiller = $aSurveiller
        })
        Write-Host ("  CRL " + [System.IO.Path]::GetFileName($src) + " : prochaine publication " + $(if ($dates.nextUpdate) { $dates.nextUpdate.ToString('dd/MM/yyyy HH:mm') } else { 'inconnue' }))
    } catch {
        Write-Warning "Lecture CRL impossible ($src) : $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# 5. Assemblage et export JSON
# ---------------------------------------------------------------------------
$chrono.Stop()
$donnees = [ordered]@{
    meta = [ordered]@{
        genere       = (Get-Date).ToString('s')
        ca           = $nomCA
        serveur      = $serveurCA
        config       = $Config
        depuis       = if ($PSBoundParameters.ContainsKey('Depuis')) { $Depuis.ToString('s') } else { $null }
        lignesLues   = $compteur
        dureeSecondes = [math]::Round($chrono.Elapsed.TotalSeconds, 1)
        outil        = ('Collecte-ADCS.ps1 v1.1.1 (lecture seule, PS ' + $PSVersionTable.PSVersion.ToString() + ')')
    }
    certificats = $certificats
    enAttente   = $enAttente
    echecs      = $echecs
    crl         = $crls
    templates   = $tpl.Liste
}

if (-not (Test-Path $Sortie)) { New-Item -ItemType Directory -Path $Sortie -Force | Out-Null }
$cheminJson = Join-Path $Sortie 'adcs-data.json'
Write-Host ("Serialisation JSON (PowerShell " + $PSVersionTable.PSVersion.ToString() + ")...")
$chronoJson = [System.Diagnostics.Stopwatch]::StartNew()
$json = ConvertTo-JsonRapide -Objet $donnees
$chronoJson.Stop()
[System.IO.File]::WriteAllText($cheminJson, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("Export : $cheminJson ($([math]::Round((Get-Item $cheminJson).Length/1KB)) Ko, serialise en $([math]::Round($chronoJson.Elapsed.TotalSeconds,1)) s)")

# ---------------------------------------------------------------------------
# 6. Optionnel : HTML auto-porteur (JSON embarque dans le visualiseur)
# ---------------------------------------------------------------------------
if ($Html) {
    if (-not (Test-Path $Html)) { throw "Visualiseur introuvable : $Html" }
    $gabarit = [System.IO.File]::ReadAllText($Html, [System.Text.Encoding]::UTF8)
    $marqueur = '<script type="application/json" id="donnees-adcs">null</script>'
    if ($gabarit.IndexOf($marqueur) -lt 0) { throw 'Marqueur d''injection introuvable dans le visualiseur (fichier modifie ?).' }
    $jsonSur = $json.Replace('</', '<\/')   # echappement JSON valide, neutralise </script>
    $autoporteur = $gabarit.Replace($marqueur, '<script type="application/json" id="donnees-adcs">' + $jsonSur + '</script>')
    $cheminAuto = Join-Path $Sortie 'visualiseur-adcs-autoporteur.html'
    [System.IO.File]::WriteAllText($cheminAuto, $autoporteur, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "HTML auto-porteur : $cheminAuto"
}

Write-Host 'Termine. Aucune ecriture n''a ete effectuee sur la CA.' -ForegroundColor Green
