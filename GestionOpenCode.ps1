<#
    Gestion OpenCode
    -----------------
    Petit utilitaire pour :
      - lister les projets connus d'OpenCode
      - lister / supprimer les sessions d'un projet
      - supprimer une session ou toutes les sessions d'un projet
      - supprimer un projet de la liste (le dossier reste sur le disque)
      - ajouter un projet (enregistre le dossier dans OpenCode)
      - ouvrir un projet dans OpenCode

    Au lancement, une console interactive s'ouvre : on ecrit en francais
    ("liste", "sessions 2", "supprime 3", "cherche discord"...).
    La commande "menu" affiche l'ancien menu numerote (-Menu au demarrage).

    Ce script utilise l'API locale d'OpenCode via "opencode api".
    Il est appele par GestionOpenCode.bat (double-clic) et peut aussi
    recevoir un chemin de dossier en argument (glisser-deposer sur le .bat).
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Path,

    [string]$Add,
    [switch]$List,
    [switch]$Menu,
    [switch]$Gui
)

$ErrorActionPreference = 'Stop'

# Affichage correct des accents dans la console.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { $Host.UI.RawUI.WindowTitle = 'Gestion OpenCode' } catch { }

# L'interface graphique a besoin de WinForms / Drawing.
if ($Gui) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
    }
    catch { }
}

$script:OcExe       = $null
$script:OcViaCmd    = $false
$script:DataDir     = Join-Path $env:USERPROFILE '.local\share\opencode'
$script:CachedProj  = $null

# Etat de la console interactive : ce que la personne est en train de regarder.
$script:DerniersProjets = @()
$script:CtxProjet       = $null
$script:CtxSessions     = @()

# ---------------------------------------------------------------------------
#  Affichage
# ---------------------------------------------------------------------------

function Write-Logo {
    $lignes = @(
        '   ___                    ____          _      ',
        '  / _ \ _ __   ___ _ __  / ___|___   __| | ___ ',
        ' | | | | ''_ \ / _ \ ''_ \| |   / _ \ / _` |/ _ \',
        ' | |_| | |_) |  __/ | | | |__| (_) | (_| |  __/',
        '  \___/| .__/ \___|_| |_|\____\___/ \__,_|\___|',
        '       |_|                                     '
    )
    Write-Host ''
    Write-Host $lignes[0] -ForegroundColor DarkCyan
    for ($i = 1; $i -lt $lignes.Count; $i++) {
        Write-Host $lignes[$i] -ForegroundColor Cyan
    }
}

function Write-Entete {
    param([string]$Titre, [string]$SousTitre = '')
    Write-Host ''
    Write-Host ('  ' + ('=' * 66)) -ForegroundColor DarkCyan
    Write-Host ('   ' + $Titre) -ForegroundColor Cyan
    if ($SousTitre) { Write-Host ('   ' + $SousTitre) -ForegroundColor DarkGray }
    Write-Host ('  ' + ('=' * 66)) -ForegroundColor DarkCyan
}

function Write-SousEntete {
    param([string]$Texte)
    Write-Host ''
    Write-Host ('  ' + $Texte) -ForegroundColor DarkGray
    Write-Host ('  ' + ('-' * 62)) -ForegroundColor DarkGray
}

function Write-Info    { param([string]$m) Write-Host ('  ' + $m) -ForegroundColor Gray }
function Write-Succes  { param([string]$m) Write-Host ('  [OK]  ' + $m) -ForegroundColor Green }
function Write-Alerte  { param([string]$m) Write-Host ('  [!]   ' + $m) -ForegroundColor Yellow }
function Write-Erreur  { param([string]$m) Write-Host ('  [X]   ' + $m) -ForegroundColor Red }
function Write-Attente { param([string]$m = 'Appuyez sur Entree pour continuer...') Read-Host ('  ' + $m) | Out-Null }

function Read-Choix {
    param([string]$Invite = 'Votre choix')
    Write-Host ('  ' + $Invite + ' : ') -NoNewline
    $valeur = $null
    try { $valeur = [Console]::In.ReadLine() } catch { return $null }
    if ($null -eq $valeur) { return $null }   # fin de l'entree (EOF)
    return ([string]$valeur).Trim()
}

# ---------------------------------------------------------------------------
#  Recherche du binaire OpenCode
# ---------------------------------------------------------------------------

function Find-OcBinary {
    if ($env:OPENCODE_GESTION_BIN -and (Test-Path -LiteralPath $env:OPENCODE_GESTION_BIN -PathType Leaf)) {
        return (Get-Item -LiteralPath $env:OPENCODE_GESTION_BIN).FullName
    }

    $candidats = New-Object System.Collections.Generic.List[string]

    # Installation "desktop" : .../ai.opencode.desktop/cli/<version>/opencode-cli.exe
    $cliDir = Join-Path $env:APPDATA 'ai.opencode.desktop\cli'
    if (Test-Path -LiteralPath $cliDir) {
        $dirs = @(Get-ChildItem -LiteralPath $cliDir -Directory -ErrorAction SilentlyContinue)
        $dirs = @($dirs | Sort-Object -Property @{ Expression = {
            try { [version](($_.Name -split '-')[0]) } catch { [version]'0.0.0' }
        } } -Descending)
        foreach ($d in $dirs) {
            $candidats.Add((Join-Path $d.FullName 'opencode-cli.exe'))
        }
    }

    $candidats.Add((Join-Path $env:LOCALAPPDATA 'Programs\ai.opencode.desktop\resources\opencode-cli.exe'))
    $candidats.Add((Join-Path $env:USERPROFILE '.opencode\bin\opencode.exe'))
    $candidats.Add((Join-Path $env:LOCALAPPDATA 'opencode\opencode.exe'))
    $candidats.Add((Join-Path $env:USERPROFILE '.bun\bin\opencode.exe'))
    $candidats.Add((Join-Path $env:APPDATA 'npm\opencode.cmd'))
    $candidats.Add((Join-Path $env:LOCALAPPDATA 'opencode-unlimited\bin\opencode.cmd'))

    foreach ($c in $candidats) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return $c }
    }

    foreach ($nom in @('opencode.exe', 'opencode')) {
        $cmd = Get-Command $nom -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }

    return $null
}

function Initialize-Oc {
    if (-not $script:OcExe) { $script:OcExe = Find-OcBinary }
    $script:OcViaCmd = [bool]($script:OcExe -and ($script:OcExe -match '\.(cmd|bat)$'))

    # Pour ouvrir l'interface, on prefere la commande "opencode" du PATH :
    # elle peut gerer le reseau/proxy propre a l'installation.
    $script:OcOpen = $script:OcExe
    foreach ($nom in @('opencode.exe', 'opencode.cmd', 'opencode')) {
        $cmd = Get-Command $nom -ErrorAction SilentlyContinue -CommandType Application, ExternalScript
        if ($cmd) { $script:OcOpen = $cmd.Source; break }
    }

    return [bool]$script:OcExe
}

# ---------------------------------------------------------------------------
#  Appels a l'API OpenCode
# ---------------------------------------------------------------------------

function ConvertTo-CmdArg {
    param([string]$Valeur)
    # Echappement des arguments pour la ligne de commande Windows :
    # - un argument vide devient ""
    # - les guillemets internes et les antislashs sont echappes comme le fait
    #   le parseur de Windows (sinon les chemins avec espaces cassent le JSON).
    if ($null -eq $Valeur) { $Valeur = '' }
    if ($Valeur -eq '') { return '""' }
    # Les metacaracteres de cmd.exe (& | < > ^) doivent aussi etre proteges :
    # sans guillemets, un "&" coupe l'argument et le reste devient une commande.
    if ($Valeur -notmatch '[\s"&|<>^()]') { return $Valeur }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $slashes = 0
    foreach ($ch in $Valeur.ToCharArray()) {
        if ($ch -eq '\') { $slashes++; continue }
        if ($ch -eq '"') {
            [void]$sb.Append(('\' * (($slashes * 2) + 1)))
            [void]$sb.Append('"')
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) { [void]$sb.Append(('\' * $slashes)); $slashes = 0 }
        [void]$sb.Append($ch)
    }
    if ($slashes -gt 0) { [void]$sb.Append(('\' * ($slashes * 2))) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Invoke-OcApi {
    param([string[]]$ArgListe)

    if (-not (Initialize-Oc)) { throw 'OpenCode est introuvable.' }

    $arguments = (@($ArgListe | ForEach-Object { ConvertTo-CmdArg ([string]$_) }) -join ' ')

    if ($script:OcViaCmd) {
        $fichier = $env:ComSpec
        $arguments = '/c ""' + $script:OcExe + '" ' + $arguments + '"'
    }
    else {
        $fichier = $script:OcExe
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName                = $fichier
    $psi.Arguments               = $arguments
    $psi.UseShellExecute         = $false
    $psi.CreateNoWindow          = $true
    $psi.RedirectStandardOutput  = $true
    $psi.RedirectStandardError   = $true
    $psi.StandardOutputEncoding  = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding   = [System.Text.Encoding]::UTF8

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    $texte = (@($stdout, $stderr) -join "`n").Trim()

    if ($proc.ExitCode -ne 0) {
        $resume = (@($texte -split "`r?`n" | Where-Object { $_ -match '\S' } | Select-Object -First 2) -join ' ').Trim()
        if (-not $resume) { $resume = "code de sortie $($proc.ExitCode)" }
        throw $resume
    }

    return $stdout.Trim()
}

function Invoke-OcGet {
    param([string]$Chemin)
    $texte = Invoke-OcApi -ArgListe @('api', 'get', $Chemin)
    if ([string]::IsNullOrWhiteSpace($texte)) { return $null }
    return ($texte | ConvertFrom-Json)
}

function Invoke-OcJson {
    param([string]$Methode, [string]$Chemin, [object]$Corps)

    $json = $Corps | ConvertTo-Json -Compress -Depth 8
    $texte = Invoke-OcApi -ArgListe @('api', $Methode, $Chemin, '--data', $json)
    if ([string]::IsNullOrWhiteSpace($texte)) { return $null }
    return ($texte | ConvertFrom-Json)
}

# ---------------------------------------------------------------------------
#  Projets
# ---------------------------------------------------------------------------

function Get-Projects {
    $liste = @(Invoke-OcGet '/api/project')
    $liste = @($liste | Where-Object { $_ -and $_.id })
    $script:CachedProj = @($liste | Sort-Object -Property @{ Expression = { $_.time.active }; Descending = $true }, canonical)
    return $script:CachedProj
}


function Get-ProjectNom {
    param($Projet)
    if ($Projet.name) { return $Projet.name }
    $leaf = Split-Path -Path $Projet.canonical -Leaf
    if ([string]::IsNullOrWhiteSpace($leaf)) { return $Projet.canonical }
    return $leaf
}

function Format-Date {
    param($Millisecondes)
    try {
        return [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$Millisecondes).LocalDateTime.ToString('dd/MM/yyyy HH:mm')
    }
    catch { return '?' }
}

function Get-SessionsRacines {
    # Toutes les sessions racines, tous projets confondus (avec pagination).
    $toutes = @()
    $curseur = $null
    $pages = 0

    do {
        $url = '/api/session?limit=500&parentID=null&archived=false'
        if ($curseur) { $url += "&cursor=$curseur" }

        $reponse = Invoke-OcGet $url
        if (-not $reponse) { break }

        foreach ($s in @($reponse.data)) {
            if ($s -and $s.id) { $toutes += $s }
        }

        $suivant = $null
        if ($reponse.cursor) { $suivant = $reponse.cursor.next }
        if (-not $suivant -or $suivant -eq $curseur) { break }

        $curseur = $suivant
        $pages++
    } while ($pages -lt 40)

    return $toutes
}

function Get-SessionsProjet {
    param([string]$ProjectId, [int]$Limite = 1000)

    $toutes = New-Object System.Collections.Generic.List[object]
    $curseur = $null
    $pages = 0

    do {
        $url = "/api/session?project=$ProjectId&limit=$Limite&archived=false"
        if ($curseur) { $url += "&cursor=$curseur" }

        $reponse = Invoke-OcGet $url
        if (-not $reponse) { break }

        foreach ($s in @($reponse.data)) {
            if ($s -and $s.id) { $toutes.Add($s) }
        }

        $suivant = $null
        if ($reponse.cursor) { $suivant = $reponse.cursor.next }
        if (-not $suivant -or $suivant -eq $curseur) { break }

        $curseur = $suivant
        $pages++
    } while ($pages -lt 25)

    return @($toutes | Sort-Object -Property @{ Expression = { $_.time.updated }; Descending = $true })
}

function Get-SessionsProjetArchivees {
    # Sessions archivees d'un projet : elles n'apparaissent plus dans la liste
    # normale mais restent en base et bloquent la suppression du projet.
    param([string]$ProjectId, [int]$Limite = 1000)

    $toutes = New-Object System.Collections.Generic.List[object]
    $curseur = $null
    $pages = 0

    do {
        $url = "/api/session?project=$ProjectId&archived=true&limit=$Limite"
        if ($curseur) { $url += "&cursor=$curseur" }

        $reponse = Invoke-OcGet $url
        if (-not $reponse) { break }

        foreach ($s in @($reponse.data)) {
            if ($s -and $s.id) { $toutes.Add($s) }
        }

        $suivant = $null
        if ($reponse.cursor) { $suivant = $reponse.cursor.next }
        if (-not $suivant -or $suivant -eq $curseur) { break }

        $curseur = $suivant
        $pages++
    } while ($pages -lt 25)

    return @($toutes | ForEach-Object { $_ })
}

function Remove-SessionsArchiveesProjet {
    # Efface les sessions archivees d'un projet (via l'API, pour que les
    # sous-sessions et messages soient nettoyes eux aussi).
    param([string]$ProjectId)

    $resultat = [pscustomobject]@{ Ok = 0; Total = 0; Erreurs = @() }
    if (-not $ProjectId) { return $resultat }

    try { $archivees = @(Get-SessionsProjetArchivees -ProjectId $ProjectId) }
    catch {
        $resultat.Erreurs = @($_.Exception.Message)
        return $resultat
    }

    $resultat.Total = $archivees.Count
    foreach ($s in $archivees) {
        try {
            Invoke-OcApi -ArgListe @('api', 'delete', "/api/session/$($s.id)") | Out-Null
            $resultat.Ok++
        }
        catch {
            $resultat.Erreurs += ('Session archivee {0} : {1}' -f $s.id, $_.Exception.Message)
        }
    }

    return $resultat
}

function Get-TitreSession {
    param($Session)
    if ($Session.title -and $Session.title.Trim()) { return $Session.title.Trim() }
    return '(sans titre)'
}

function Get-Tronque {
    param([string]$Texte, [int]$Max = 58)
    if ($null -eq $Texte) { return '' }
    if ($Texte.Length -le $Max) { return $Texte }
    return $Texte.Substring(0, $Max - 3) + '...'
}

function Get-Racines {
    param($Sessions)
    # On n'affiche que les sessions "racines" : supprimer une session racine
    # supprime aussi ses sessions enfants (sous-agents).
    if ($null -eq $Sessions) { return @() }
    return @($Sessions | Where-Object { -not $_.parentID })
}

function Get-NombreEnfants {
    param($Sessions, [string]$Id)
    return @($Sessions | Where-Object { $_.parentID -eq $Id }).Count
}

# ---------------------------------------------------------------------------
#  Base de donnees (suppression definitive d'un projet)
# ---------------------------------------------------------------------------

function Get-OcDbPath {
    if ($script:OcDbPath -and (Test-Path -LiteralPath $script:OcDbPath -PathType Leaf)) {
        return $script:OcDbPath
    }

    $chemin = ''
    try {
        $sortie = Invoke-OcApi -ArgListe @('debug', 'paths')
        foreach ($ligne in @($sortie -split "`r?`n")) {
            if ($ligne -match '^\s*db\s+(\S.*?)\s*$') {
                $chemin = $Matches[1].Trim()
                break
            }
        }
    }
    catch { }

    if (-not $chemin) {
        $chemin = Join-Path $env:USERPROFILE '.local\share\opencode\opencode.db'
    }

    $script:OcDbPath = $chemin
    return $chemin
}

function Initialize-OcDbHelper {
    # Acces SQLite sans dependance : on utilise la DLL fournie par Windows.
    if ('OcSqlite' -as [type]) { return $true }

    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class OcSqlite
{
    private const int SQLITE_OK = 0;
    private const int SQLITE_ROW = 100;
    private const int SQLITE_DONE = 101;
    private const int SQLITE_OPEN_READWRITE = 0x00000002;

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_open_v2(byte[] filename, out IntPtr db, int flags, IntPtr vfs);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_close(IntPtr db);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_busy_timeout(IntPtr db, int ms);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int nByte, out IntPtr stmt, IntPtr tail);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_step(IntPtr stmt);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_finalize(IntPtr stmt);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_bind_text(IntPtr stmt, int index, byte[] value, int n, IntPtr destructor);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern long sqlite3_column_int64(IntPtr stmt, int col);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_changes(IntPtr db);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr sqlite3_errmsg(IntPtr db);

    public static long Execute(string dbPath, string sql, string[] args)
    {
        IntPtr db = IntPtr.Zero;
        IntPtr stmt = IntPtr.Zero;
        try
        {
            int rc = sqlite3_open_v2(Bytes(dbPath), out db, SQLITE_OPEN_READWRITE, IntPtr.Zero);
            if (rc != SQLITE_OK) throw new Exception("Ouverture de la base impossible (code " + rc + ")");
            sqlite3_busy_timeout(db, 8000);

            rc = sqlite3_prepare_v2(db, Bytes(sql), -1, out stmt, IntPtr.Zero);
            if (rc != SQLITE_OK) throw new Exception("Requete refusee (code " + rc + ") : " + Message(db));

            if (args != null)
            {
                for (int i = 0; i < args.Length; i++)
                {
                    rc = sqlite3_bind_text(stmt, i + 1, Bytes(args[i]), -1, new IntPtr(-1));
                    if (rc != SQLITE_OK) throw new Exception("Parametre refuse (code " + rc + ") : " + Message(db));
                }
            }

            long valeur = 0;
            bool ligne = false;
            while (true)
            {
                rc = sqlite3_step(stmt);
                if (rc == SQLITE_ROW) { valeur = sqlite3_column_int64(stmt, 0); ligne = true; continue; }
                if (rc == SQLITE_DONE) break;
                throw new Exception("Execution refusee (code " + rc + ") : " + Message(db));
            }

            if (!ligne) valeur = (long)sqlite3_changes(db);
            return valeur;
        }
        finally
        {
            if (stmt != IntPtr.Zero) sqlite3_finalize(stmt);
            if (db != IntPtr.Zero) sqlite3_close(db);
        }
    }

    private static byte[] Bytes(string texte)
    {
        if (texte == null) texte = "";
        byte[] brut = System.Text.Encoding.UTF8.GetBytes(texte);
        byte[] fin = new byte[brut.Length + 1];
        Array.Copy(brut, fin, brut.Length);
        return fin;
    }

    private static string Message(IntPtr db)
    {
        if (db == IntPtr.Zero) return "?";
        return Marshal.PtrToStringAnsi(sqlite3_errmsg(db));
    }
}
'@ -ErrorAction Stop

        return $true
    }
    catch {
        return $false
    }
}

function Remove-ProjetBase {
    # Retire un projet de la base OpenCode. Le dossier sur le disque n'est PAS touche.
    param([string]$ProjectId)

    if (-not $ProjectId) { throw 'Identifiant de projet manquant.' }
    if (-not (Initialize-OcDbHelper)) {
        throw 'Acces a la base OpenCode impossible sur cet ordinateur.'
    }

    $db = Get-OcDbPath
    if (-not (Test-Path -LiteralPath $db -PathType Leaf)) {
        throw ('Base OpenCode introuvable : ' + $db)
    }

    $restantes = [OcSqlite]::Execute($db, 'select count(*) from session_v2 where project_id = ?', @($ProjectId))
    if ($restantes -gt 0) {
        throw ("{0} session(s) sont encore rattachees a ce projet (y compris les sessions archivees). Supprimez-les d'abord." -f $restantes)
    }

    $resultat = [pscustomobject]@{
        Worktrees   = 0
        Repertoires = 0
        Projet      = 0
    }

    $resultat.Worktrees   = [OcSqlite]::Execute($db, 'delete from worktree where project_id = ?', @($ProjectId))
    $resultat.Repertoires = [OcSqlite]::Execute($db, 'delete from project_directory where project_id = ?', @($ProjectId))
    $resultat.Projet      = [OcSqlite]::Execute($db, 'delete from project where id = ?', @($ProjectId))

    $verif = [OcSqlite]::Execute($db, 'select count(*) from project where id = ?', @($ProjectId))
    if ($verif -ne 0) {
        throw 'Le projet est toujours present dans la base OpenCode.'
    }

    return $resultat
}

# ---------------------------------------------------------------------------
#  Actions
# ---------------------------------------------------------------------------

function Remove-SessionIds {
    param([string[]]$Ids)

    if (-not $Ids -or $Ids.Count -eq 0) { return }

    $ok = 0
    $ko = 0
    $afficherProgression = $Ids.Count -gt 1
    $i = 0

    foreach ($id in $Ids) {
        $i++
        if ($afficherProgression) {
            Write-Host ("`r  Suppression {0}/{1}..." -f $i, $Ids.Count) -NoNewline -ForegroundColor DarkGray
        }
        try {
            Invoke-OcApi -ArgListe @('api', 'delete', "/api/session/$id") | Out-Null
            $ok++
        }
        catch {
            $ko++
            if ($afficherProgression) {
                Write-Host ("`r" + (' ' * 40) + "`r") -NoNewline
            }
            else {
                Write-Host ''
            }
            Write-Erreur ("Echec pour la session {0}" -f $id)
            Write-Info ($_.Exception.Message)
        }
    }

    if ($afficherProgression) {
        Write-Host ("`r" + (' ' * 40) + "`r") -NoNewline
    }

    Write-Host ''
    Write-Host ''

    if ($ok -gt 0) {
        Write-Succes ("{0} session(s) supprimee(s)." -f $ok)
    }
    if ($ko -gt 0) {
        Write-Erreur ("{0} session(s) n'ont pas pu etre supprimees." -f $ko)
        Write-Info 'Si une session est ouverte dans OpenCode, fermez-la puis reessayez.'
        Write-Info 'Vous pouvez relancer la suppression : les sessions deja effacees ont disparu de la liste.'
    }

    return $ok
}

function Add-Projet {
    param([string]$Chemin)

    Write-Entete 'Ajouter un projet'

    if (-not $Chemin) {
        Write-Info 'Indiquez le dossier du projet.'
        Write-Info 'Astuce : vous pouvez glisser-deposer le dossier dans cette fenetre.'
        Write-Host ''
        $Chemin = Read-Choix 'Chemin du dossier'
    }

    if (-not $Chemin) { Write-Alerte 'Aucun chemin fourni.'; return $false }

    $Chemin = $Chemin.Trim().Trim('"').Trim("'")
    try { $Chemin = [Environment]::ExpandEnvironmentVariables($Chemin) } catch { }

    if (-not (Test-Path -LiteralPath $Chemin -PathType Container)) {
        Write-Erreur ("Le dossier n'existe pas : {0}" -f $Chemin)
        return $false
    }

    $resolu = (Resolve-Path -LiteralPath $Chemin).ProviderPath

    Write-Host ''
    Write-Info ("Dossier : {0}" -f $resolu)

    # Le projet est connu si une session existe deja dans ce dossier.
    try {
        $projets = @(Get-Projects)
        $existant = $projets | Where-Object { $_.canonical.TrimEnd('\') -ieq $resolu.TrimEnd('\') } | Select-Object -First 1
        if ($existant) {
            Write-Alerte 'Ce dossier est deja enregistre comme projet.'
            Write-Info ("Projet : {0}" -f (Get-ProjectNom $existant))
            if ((Read-Choix 'L''ouvrir dans OpenCode ? (o/N)') -match '^(o|oui|y)$') {
                Open-Projet $existant
            }
            return $true
        }
    }
    catch {
        Write-Alerte ("Impossible de lire la liste des projets : {0}" -f $_.Exception.Message)
    }

    try {
        Write-Host ''
        Write-Info 'Enregistrement du projet dans OpenCode...'
        $reponse = Invoke-OcJson -Methode 'post' -Chemin '/api/session' -Corps @{ location = @{ directory = $resolu } }
        if (-not $reponse -or -not $reponse.data) { throw 'reponse inattendue du serveur' }

        Write-Succes ("Projet enregistre : {0}" -f $resolu)
        Write-Info ("Identifiant du projet : {0}" -f $reponse.data.projectID)

        Write-Host ''
        if ((Read-Choix 'Ouvrir ce projet dans OpenCode maintenant ? (o/N)') -match '^(o|oui|y)$') {
            Open-Projet ([pscustomobject]@{ canonical = $resolu; id = $reponse.data.projectID })
        }

        return $true
    }
    catch {
        Write-Erreur ("Echec de l'ajout du projet : {0}" -f $_.Exception.Message)
        Write-Info "Verifiez qu'OpenCode est bien installe et demarre."
        return $false
    }
}

function Open-Projet {
    param($Projet)

    $dir = $Projet.canonical
    if (-not $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) {
        Write-Erreur ("Dossier introuvable : {0}" -f $dir)
        return
    }

    if (-not (Initialize-Oc)) { return }

    # On utilise la commande "opencode" quand elle est disponible : elle sait
    # ouvrir l'application de bureau. Sinon on retombe sur le binaire trouve.
    $lanceur = $script:OcOpen
    if (-not $lanceur) { $lanceur = $script:OcExe }
    try {
        if ($lanceur -match '\.(cmd|bat)$') {
            Start-Process -FilePath $env:ComSpec -ArgumentList '/c', "`"$lanceur`" `"$dir`"" -WorkingDirectory $dir | Out-Null
        }
        else {
            Start-Process -FilePath $lanceur -ArgumentList "`"$dir`"" -WorkingDirectory $dir | Out-Null
        }
        Write-Succes ("OpenCode a ete lance dans : {0}" -f $dir)
        Write-Info 'Une nouvelle fenetre OpenCode vient de s''ouvrir.'
    }
    catch {
        Write-Erreur ("Lancement impossible : {0}" -f $_.Exception.Message)
    }
}

# ---------------------------------------------------------------------------
#  Ecrans
# ---------------------------------------------------------------------------

function Show-Projets {
    Write-Entete 'Liste des projets'

    try { $projets = @(Get-Projects) }
    catch {
        Write-Erreur ("Lecture des projets impossible : {0}" -f $_.Exception.Message)
        Write-Attente
        return
    }

    if ($projets.Count -eq 0) {
        Write-Alerte 'Aucun projet enregistre pour le moment.'
        Write-Info 'Utilisez "Ajouter un projet" ou lancez OpenCode dans un dossier.'
        Write-Host ''
        Write-Attente
        return
    }

    Write-Host ''
    Write-Host ('   #   Projet                           Sessions   Derniere activite') -ForegroundColor DarkGray
    Write-Host ('   -   ------------------------------   --------   -----------------') -ForegroundColor DarkGray

    $i = 0
    foreach ($p in $projets) {
        $i++
        $nb = 0
        try { $nb = @(Get-Racines (Get-SessionsProjet -ProjectId $p.id)).Count } catch { $nb = -1 }

        $nom = Get-Tronque (Get-ProjectNom $p) 28
        $nbTxt = if ($nb -ge 0) { '{0,8}' -f $nb } else { '{0,8}' -f '?' }
        $date = Format-Date $p.time.active
        if (-not $date -or $date -eq '01/01/1970 01:00') { $date = Format-Date $p.time.updated }

        Write-Host ("   {0,-3} {1,-28}   {2}   {3}" -f $i, $nom, $nbTxt, $date) -ForegroundColor White
        Write-Host ("       {0}" -f (Get-Tronque $p.canonical 70)) -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Info ("{0} projet(s) - donnees : {1}" -f $projets.Count, $script:DataDir)
    Write-Host ''
    Write-Attente
}

function Select-Projet {
    param([string]$Titre)

    try { $projets = @(Get-Projects) }
    catch {
        Write-Erreur ("Lecture des projets impossible : {0}" -f $_.Exception.Message)
        return $null
    }

    if ($projets.Count -eq 0) {
        Write-Alerte 'Aucun projet enregistre.'
        return $null
    }

    Write-SousEntete $Titre
    Write-Host ''
    $i = 0
    foreach ($p in $projets) {
        $i++
        Write-Host ("   {0,2}. {1}" -f $i, (Get-ProjectNom $p)) -ForegroundColor White
        Write-Host ("       {0}" -f (Get-Tronque $p.canonical 70)) -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Info '   0. Retour'
    Write-Host ''

    $choix = Read-Choix 'Numero du projet'
    if ($choix -eq '0' -or -not $choix) { return $null }

    $num = 0
    if (-not [int]::TryParse($choix, [ref]$num)) {
        Write-Alerte 'Choix invalide.'
        return $null
    }
    if ($num -lt 1 -or $num -gt $projets.Count) {
        Write-Alerte 'Numero hors limites.'
        return $null
    }

    return $projets[$num - 1]
}

function Show-DetailSession {
    param($Session)

    Write-Entete 'Detail de la session'
    Write-Info ("Titre        : {0}" -f (Get-TitreSession $Session))
    Write-Info ("Identifiant  : {0}" -f $Session.id)
    Write-Info ("Projet       : {0}" -f $Session.projectID)
    Write-Info ("Dossier      : {0}" -f $Session.location.directory)
    Write-Info ("Creee le     : {0}" -f (Format-Date $Session.time.created))
    Write-Info ("Modifiee le  : {0}" -f (Format-Date $Session.time.updated))
    if ($Session.agent) { Write-Info ("Agent        : {0}" -f $Session.agent) }
    if ($Session.model) { Write-Info ("Modele       : {0}/{1}" -f $Session.model.providerID, $Session.model.id) }
    if ($Session.parentID) { Write-Info ("Session mere : {0}" -f $Session.parentID) }
    if ($null -ne $Session.cost) { Write-Info ("Cout         : {0}" -f $Session.cost) }
    if ($Session.tokens) { Write-Info ("Jetons       : entree {0} / sortie {1}" -f $Session.tokens.input, $Session.tokens.output) }
    if ($Session.outcome) { Write-Info ("Resultat     : {0}" -f $Session.outcome) }
    Write-Host ''
}

function Confirm-Suppression {
    param(
        [object[]]$Cibles,
        $Sessions,
        [string]$Question = ''
    )

    Write-Host ''
    Write-Host '  Sessions qui vont etre supprimees :' -ForegroundColor Yellow
    foreach ($s in $Cibles) {
        $enfants = 0
        if ($Sessions) { $enfants = Get-NombreEnfants $Sessions $s.id }
        Write-Host ('    - ' + (Get-Tronque (Get-TitreSession $s) 52)) -ForegroundColor White
        if ($enfants -gt 0) {
            Write-Host ('      ' + $s.id + '  (+ ' + $enfants + ' sous-session(s) supprimee(s) aussi)') -ForegroundColor DarkGray
        }
        else {
            Write-Host ('      ' + $s.id) -ForegroundColor DarkGray
        }
    }
    Write-Host ''
    Write-Info 'La suppression est definitive.'
    Write-Host ''
    if (-not $Question) {
        $Question = 'Confirmer la suppression de ' + $Cibles.Count + ' session(s) ? (o/N)'
    }
    $reponse = Read-Choix $Question
    return [bool]($reponse -match '^(o|oui|y)$')
}

function Show-TableSessions {
    param($Racines, $Sessions)

    Write-Host '   #    Derniere modif.     Titre' -ForegroundColor DarkGray
    Write-Host '   ---  ------------------  ---------------------------------------------------' -ForegroundColor DarkGray
    $i = 0
    foreach ($s in $Racines) {
        $i++
        $enfants = Get-NombreEnfants $Sessions $s.id
        $marque = ''
        if ($enfants -gt 0) { $marque = "  (+$enfants)" }
        Write-Host ("   {0,-3}  {1}  {2}{3}" -f $i, (Format-Date $s.time.updated), (Get-Tronque (Get-TitreSession $s) 46), $marque) -ForegroundColor White
        Write-Host ("        {0}" -f $s.id) -ForegroundColor DarkGray
    }
}

function Gerer-Projet {
    param($Projet)

    while ($true) {
        $sessions = @()
        try { $sessions = @(Get-SessionsProjet -ProjectId $Projet.id) }
        catch {
            Write-Entete 'Erreur'
            Write-Erreur ("Lecture des sessions impossible : {0}" -f $_.Exception.Message)
            Write-Attente
            return
        }

        $racines = @(Get-Racines $sessions)

        Write-Entete ('Projet : ' + (Get-ProjectNom $Projet)) $Projet.canonical
        if ($racines.Count -gt 0) {
            Write-Info ("Sessions : {0} principale(s), {1} sous-session(s)" -f $racines.Count, ($sessions.Count - $racines.Count))
        }
        Write-Host ''

        if ($racines.Count -eq 0) {
            Write-Alerte 'Ce projet ne contient aucune session.'
            Write-Host ''
            Write-Host '   1.  Creer une session dans ce projet' -ForegroundColor White
            Write-Host '   2.  Ouvrir le projet dans OpenCode' -ForegroundColor White
            Write-Host '   0.  Retour au menu' -ForegroundColor DarkGray
            Write-Host ''

            $c = Read-Choix 'Action'
            if ($null -eq $c -or $c -eq '0') { return }

            if ($c -eq '1') {
                try {
                    $reponse = Invoke-OcJson -Methode 'post' -Chemin '/api/session' -Corps @{ location = @{ directory = $Projet.canonical } }
                    Write-Succes 'Nouvelle session creee.'
                    if ($reponse -and $reponse.data) { Write-Info ("Identifiant : {0}" -f $reponse.data.id) }
                }
                catch { Write-Erreur ("Creation impossible : {0}" -f $_.Exception.Message) }
                Write-Attente
            }
            elseif ($c -eq '2') {
                Open-Projet $Projet
                Write-Attente
            }
            continue
        }

        Show-TableSessions $racines $sessions

        Write-Host ''
        Write-Host '   ACTIONS' -ForegroundColor Cyan
        Write-Host '   1.  Supprimer une ou plusieurs sessions' -ForegroundColor White
        Write-Host '   2.  Supprimer TOUTES les sessions de ce projet' -ForegroundColor White
        Write-Host '   3.  Afficher le detail d''une session' -ForegroundColor White
        Write-Host '   4.  Renommer le projet' -ForegroundColor White
        Write-Host '   5.  Ouvrir le projet dans OpenCode' -ForegroundColor White
        Write-Host '   0.  Retour au menu' -ForegroundColor DarkGray
        Write-Host ''

        $choix = Read-Choix 'Action'
        if ($null -eq $choix -or $choix -eq '0') { return }

        switch ($choix) {
            '1' {
                $liste = Read-Choix 'Numero(s) de session a supprimer (ex: 2 ou 1,3) - Entree pour annuler'
                if (-not $liste) { continue }

                $numeros = @(($liste -split '[\s,;]+') | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ } | Sort-Object -Unique)
                $cibles = @()
                foreach ($n in $numeros) {
                    if ($n -ge 1 -and $n -le $racines.Count) { $cibles += $racines[$n - 1] }
                }

                if ($cibles.Count -eq 0) {
                    Write-Alerte 'Aucun numero valide.'
                    Start-Sleep -Milliseconds 800
                    continue
                }

                if (Confirm-Suppression -Cibles $cibles -Sessions $sessions) {
                    Remove-SessionIds -Ids @($cibles | ForEach-Object { $_.id })
                    Write-Attente
                }
                else {
                    Write-Info 'Suppression annulee.'
                    Start-Sleep -Milliseconds 700
                }
                continue
            }

            '2' {
                Write-Host ''
                Write-Alerte ("Vous allez supprimer les {0} session(s) de ce projet." -f $racines.Count)
                if ($sessions.Count -gt $racines.Count) {
                    Write-Alerte ("Les {0} sous-session(s) seront aussi supprimees." -f ($sessions.Count - $racines.Count))
                }

                if (-not (Confirm-Suppression -Cibles $racines -Sessions $sessions -Question 'Supprimer TOUTES les sessions de ce projet ? (o/N)')) {
                    Write-Info 'Suppression annulee.'
                    Start-Sleep -Milliseconds 700
                    continue
                }

                Remove-SessionIds -Ids @($racines | ForEach-Object { $_.id })
                Write-Attente
                continue
            }

            '3' {
                $n = 0
                $saisie = Read-Choix 'Numero de la session'
                if (-not [int]::TryParse($saisie, [ref]$n) -or $n -lt 1 -or $n -gt $racines.Count) {
                    Write-Alerte 'Numero invalide.'
                    Start-Sleep -Milliseconds 800
                    continue
                }
                Show-DetailSession $racines[$n - 1]
                Write-Attente
                continue
            }

            '4' {
                Write-Host ''
                $nouveau = Read-Choix 'Nouveau nom du projet (Entree = annuler)'
                if ($nouveau) {
                    try {
                        Invoke-OcJson -Methode 'patch' -Chemin ("/api/project/" + $Projet.id) -Corps @{ name = $nouveau } | Out-Null
                        Write-Succes 'Nom du projet mis a jour.'
                        $Projet | Add-Member -NotePropertyName name -NotePropertyValue $nouveau -Force
                    }
                    catch {
                        Write-Erreur ("Renommage impossible : {0}" -f $_.Exception.Message)
                    }
                    Write-Attente
                }
                continue
            }

            '5' {
                Open-Projet $Projet
                Write-Attente
                continue
            }

            default {
                Write-Alerte 'Choix invalide.'
                Start-Sleep -Milliseconds 700
            }
        }
    }
}

function Supprimer-SessionsProjet {
    param($Projet)
    if (-not $Projet) { return 0 }

    Write-Host ''
    Write-Host ('  Projet : ' + (Get-ProjectNom $Projet)) -ForegroundColor Cyan
    Write-Host ('  Dossier : ' + $Projet.canonical) -ForegroundColor DarkGray

    try { $sessions = @(Get-SessionsProjet -ProjectId $Projet.id) }
    catch {
        Write-Erreur ("Lecture des sessions impossible : {0}" -f $_.Exception.Message)
        return 0
    }

    $racines = @(Get-Racines $sessions)
    if ($racines.Count -eq 0) {
        Write-Alerte 'Ce projet ne contient aucune session.'
        return 0
    }

    Write-Alerte ("{0} session(s) au total, dont {1} sous-session(s)." -f $sessions.Count, ($sessions.Count - $racines.Count))
    Write-Alerte 'Cette action est definitive.'

    $question = "Supprimer TOUTES les sessions de ce projet ? (o/N)"
    if (-not (Confirm-Suppression -Cibles $racines -Sessions $sessions -Question $question)) {
        Write-Info 'Suppression annulee.'
        return 0
    }

    return (Remove-SessionIds -Ids @($racines | ForEach-Object { $_.id }))
}

function Supprimer-ToutesSessionsProjet {
    $projet = Select-Projet 'Supprimer toutes les sessions d''un projet'
    if (-not $projet) { return }
    Supprimer-SessionsProjet $projet | Out-Null
    Write-Attente
}

function Supprimer-ProjetConsole {
    param(
        $Projet = $null,
        [string]$Cible = ''
    )

    if (-not $Projet) {
        if ($Cible) { $Projet = Resolve-Projet $Cible }
        elseif ($script:CtxProjet) { $Projet = $script:CtxProjet }
        else { $Projet = Select-Projet 'Supprimer un projet' }
    }
    if (-not $Projet) { return }

    Write-Entete 'Supprimer un projet'

    try { $sessions = @(Get-SessionsProjet -ProjectId $Projet.id) }
    catch {
        Write-Erreur ("Lecture des sessions impossible : {0}" -f $_.Exception.Message)
        Write-Attente
        return
    }

    $racines = @(Get-Racines $sessions)

    Write-Info ("Projet   : {0}" -f (Get-ProjectNom $Projet))
    Write-Info ("Dossier  : {0}" -f $Projet.canonical)
    Write-Info ("Sessions : {0} (dont {1} sous-session(s))" -f $sessions.Count, ($sessions.Count - $racines.Count))
    Write-Host ''
    Write-Alerte 'Le projet sera retire de la liste OpenCode et ses sessions seront supprimees.'
    Write-Succes 'Le dossier sur le disque reste intact : aucun fichier n''est efface.'
    Write-Host ''

    $confirme = Read-Choix 'Confirmer la suppression du projet ? (o/N)'
    if ($confirme -notmatch '^(o|oui|y)$') {
        Write-Info 'Suppression annulee.'
        Start-Sleep -Milliseconds 700
        return
    }

    # OpenCode peut recreer un projet des qu'un client utilise son dossier.
    if ($racines.Count -gt 0) {
        Write-Host ''
        Remove-SessionIds -Ids @($racines | ForEach-Object { $_.id }) | Out-Null
    }

    # Les sessions archivees restent en base : on les efface aussi, sinon
    # Remove-ProjetBase refuse la suppression du projet.
    $archivees = Remove-SessionsArchiveesProjet -ProjectId $Projet.id
    if ($archivees.Total -gt 0) {
        Write-Info ("{0} session(s) archivee(s) effacee(s)." -f $archivees.Ok)
    }
    foreach ($e in @($archivees.Erreurs)) { Write-Erreur $e }

    try {
        $reste = @(Get-SessionsProjet -ProjectId $Projet.id)
    }
    catch {
        $reste = @()
    }

    if ($reste.Count -gt 0) {
        Write-Host ''
        Write-Erreur ("{0} session(s) n'ont pas pu etre supprimees." -f $reste.Count)
        Write-Info 'Fermez la session dans OpenCode puis relancez la suppression.'
        Write-Attente
        return
    }

    Write-Host ''
    try {
        Remove-ProjetBase -ProjectId $Projet.id | Out-Null
        Write-Succes ('Projet supprime : ' + (Get-ProjectNom $Projet))
    }
    catch {
        Write-Erreur ('La suppression du projet a echoue : ' + $_.Exception.Message)
        Write-Info 'Fermez OpenCode puis reessayez.'
        Write-Attente
        return
    }

    $script:CtxProjet = $null
    $script:CtxSessions = @()
    Write-Attente
    Show-ProjetsListe
}

function Rechercher-Et-Supprimer {
    $recherche = Read-Choix 'Texte a rechercher dans les titres (Entree = toutes)'

    Write-Entete 'Sessions trouvees'
    try {
        $url = '/api/session?limit=1000&archived=false'
        if ($recherche) { $url += '&search=' + [uri]::EscapeDataString($recherche) }
        $reponse = Invoke-OcGet $url
    }
    catch {
        Write-Erreur ("Recherche impossible : {0}" -f $_.Exception.Message)
        Write-Attente
        return
    }

    if (-not $reponse) { Write-Alerte 'Aucun resultat.'; Write-Attente; return }

    $toutes = @($reponse.data)
    $racines = @(Get-Racines $toutes)
    if ($racines.Count -eq 0) {
        Write-Alerte 'Aucune session trouvee.'
        Write-Attente
        return
    }

    try { $projets = @(Get-Projects) } catch { $projets = @() }
    $nomsProjets = @{}
    foreach ($p in $projets) { $nomsProjets[$p.id] = Get-ProjectNom $p }

    Write-Info ("{0} session(s) trouvee(s) - 25 premieres affichees" -f $racines.Count)
    Write-Host ''

    $i = 0
    foreach ($s in $racines) {
        $i++
        $nomProjet = ''
        if ($nomsProjets.ContainsKey($s.projectID)) {
            $nomProjet = $nomsProjets[$s.projectID]
        }
        elseif ($s.location -and $s.location.directory) {
            $nomProjet = Split-Path -Leaf ([string]$s.location.directory)
        }
        else { $nomProjet = [string]$s.projectID }
        if ($i -le 25) {
            Write-Host ("   {0,-3} {1}  {2}" -f $i, (Format-Date $s.time.updated), (Get-Tronque (Get-TitreSession $s) 44)) -ForegroundColor White
            Write-Host ("        {0}  [{1}]" -f $s.id, (Get-Tronque $nomProjet 30)) -ForegroundColor DarkGray
        }
    }
    if ($racines.Count -gt 25) { Write-Info ("... et {0} autre(s)" -f ($racines.Count - 25)) }

    Write-Host ''
    Write-Host '   ACTIONS' -ForegroundColor Cyan
    Write-Host '   1.  Supprimer une ou plusieurs sessions de cette liste' -ForegroundColor White
    Write-Host '   0.  Retour au menu' -ForegroundColor DarkGray
    Write-Host ''
    $choix = Read-Choix 'Action'
    if ($null -eq $choix -or $choix -ne '1') { return }

    $liste = Read-Choix 'Numero(s) a supprimer (ex: 2 ou 1,3) - Entree pour annuler'
    if (-not $liste) { return }

    $numeros = @(($liste -split '[\s,;]+') | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ } | Sort-Object -Unique)
    $cibles = @()
    foreach ($n in $numeros) {
        if ($n -ge 1 -and $n -le $racines.Count) { $cibles += $racines[$n - 1] }
    }
    if ($cibles.Count -eq 0) { Write-Alerte 'Aucun numero valide.'; Write-Attente; return }

    if (Confirm-Suppression -Cibles $cibles -Sessions $toutes) {
        Remove-SessionIds -Ids @($cibles | ForEach-Object { $_.id })
        Write-Attente
    }
    else {
        Write-Info 'Suppression annulee.'
        Start-Sleep -Milliseconds 700
    }
}

function Purger-Tout {
    Write-Entete 'Supprimer toutes les sessions'
    Write-Alerte 'Cette action supprime les sessions de TOUS les projets.'
    Write-Info 'Les dossiers des projets restent en place : seules les conversations sont effacees.'
    Write-Host ''

    try { $racines = @(Get-SessionsRacines) }
    catch {
        Write-Erreur ("Lecture des sessions impossible : {0}" -f $_.Exception.Message)
        Write-Attente
        return
    }

    if ($racines.Count -eq 0) {
        Write-Alerte 'Aucune session a supprimer.'
        Write-Attente
        return
    }

    try { $projets = @(Get-Projects) } catch { $projets = @() }
    Write-Alerte ("{0} session(s) vont etre supprimees, sur {1} projet(s)." -f $racines.Count, $projets.Count)
    Write-Info 'La suppression est definitive.'
    Write-Host ''

    $confirm = Read-Choix 'Tapez SUPPRIMER TOUT pour confirmer'
    if ($confirm -ne 'SUPPRIMER TOUT') {
        Write-Info 'Operation annulee.'
        Start-Sleep -Milliseconds 800
        return
    }

    Remove-SessionIds -Ids @($racines | ForEach-Object { $_.id })
    Write-Attente
}

function Show-Infos {
    Write-Entete 'Informations'

    $bin = Find-OcBinary
    if ($bin) {
        Write-Succes ("Programme OpenCode : {0}" -f $bin)
    }
    else {
        Write-Erreur 'Programme OpenCode introuvable.'
    }

    if ($bin) {
        try {
            $version = (Invoke-OcApi -ArgListe @('--version')).Trim()
            Write-Info ("Version            : {0}" -f $version)
        }
        catch { Write-Alerte 'Version indisponible.' }
    }

    Write-Info ("Donnees OpenCode    : {0}" -f $script:DataDir)
    if (Test-Path -LiteralPath (Join-Path $script:DataDir 'opencode.db')) {
        Write-Succes 'Base de donnees trouvee.'
    }
    else {
        Write-Alerte 'Base de donnees introuvable (OpenCode n''a peut-etre jamais ete lance).'
    }

    try {
        $projets = @(Get-Projects)
        $racines = @(Get-SessionsRacines)
        Write-Info ("Projets connus      : {0}" -f $projets.Count)
        Write-Info ("Sessions            : {0}" -f $racines.Count)
    }
    catch {
        Write-Alerte ("Statistiques indisponibles : {0}" -f $_.Exception.Message)
    }

    Write-Host ''
    Write-Info 'Variable OPENCODE_GESTION_BIN : chemin force vers le binaire OpenCode.'
    Write-Host ''
    Write-Attente
}

# ---------------------------------------------------------------------------
#  Menu principal
# ---------------------------------------------------------------------------

function Show-Menu {
    Clear-Host
    Write-Logo
    Write-Host ''
    Write-Host '       Gestion des projets et des sessions OpenCode' -ForegroundColor White
    Write-Host ('  ' + ('-' * 66)) -ForegroundColor DarkCyan
    Write-Host ''
    Write-Host '   PROJETS' -ForegroundColor Cyan
    Write-Host '   1.  Voir les projets et leurs sessions' -ForegroundColor White
    Write-Host '   2.  Ajouter un projet' -ForegroundColor White
    Write-Host '   3.  Ouvrir un projet dans OpenCode' -ForegroundColor White
    Write-Host '   4.  Supprimer un projet' -ForegroundColor DarkYellow
    Write-Host ''
    Write-Host '   SESSIONS' -ForegroundColor Cyan
    Write-Host '   5.  Gerer un projet : voir / supprimer ses sessions' -ForegroundColor White
    Write-Host '   6.  Rechercher une session puis la supprimer' -ForegroundColor White
    Write-Host '   7.  Supprimer toutes les sessions d''un projet' -ForegroundColor White
    Write-Host '   8.  Supprimer TOUTES les sessions (tous les projets)' -ForegroundColor DarkYellow
    Write-Host ''
    Write-Host '   AUTRES' -ForegroundColor Cyan
    Write-Host '   9.  Informations / diagnostic' -ForegroundColor White
    Write-Host ''
    Write-Host '   0.  Quitter' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '   Tapez le numero de votre choix puis Entree.' -ForegroundColor DarkGray
    Write-Host ''
}

# ---------------------------------------------------------------------------
#  Console interactive (mode conversation)
# ---------------------------------------------------------------------------

function Convert-SansAccent {
    param([string]$Texte)
    if ($null -eq $Texte) { return '' }
    $propre = $Texte.Replace([char]0x2019, "'").Replace([char]0x2018, "'")
    $normalise = $propre.Normalize([System.Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $normalise.ToCharArray()) {
        if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($c)
        }
    }
    $plat = $sb.ToString().Normalize([System.Text.NormalizationForm]::FormC)
    return ($plat.ToLowerInvariant() -replace '\s+', ' ').Trim()
}

function Get-PromptContexte {
    if ($script:CtxProjet) {
        $nom = Get-Tronque (Get-ProjectNom $script:CtxProjet) 26
        if ($script:CtxSessions.Count -gt 0) {
            return ("projet {0} - {1} session(s)" -f $nom, $script:CtxSessions.Count)
        }
        return ('projet ' + $nom)
    }
    if ($script:CtxSessions.Count -gt 0) {
        return ("{0} session(s) trouvee(s)" -f $script:CtxSessions.Count)
    }
    if ($script:DerniersProjets.Count -gt 0) {
        return ("{0} projet(s)" -f $script:DerniersProjets.Count)
    }
    return 'accueil'
}

function Read-Commande {
    Write-Host ''
    Write-Host ('  [' + (Get-PromptContexte) + ']') -ForegroundColor DarkCyan
    Write-Host '  > ' -NoNewline -ForegroundColor Cyan
    try { return [Console]::In.ReadLine() } catch { return $null }
}

function Show-Aide {
    Write-Host ''
    Write-Host '  Voici ce que vous pouvez me dire :' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '    liste                    voir les projets (numerotes)' -ForegroundColor White
    Write-Host '    sessions 2               voir les sessions du projet 2' -ForegroundColor White
    Write-Host '    sessions discord         pareil, en cherchant par nom' -ForegroundColor White
    Write-Host '    cherche discord          chercher des sessions par titre' -ForegroundColor White
    Write-Host ''
    Write-Host '    supprime 2               supprimer la session 2 de la liste affichee' -ForegroundColor White
    Write-Host '    supprime 1,3             supprimer plusieurs sessions' -ForegroundColor White
    Write-Host '    supprime 2               (depuis la liste des projets) vider le projet 2' -ForegroundColor White
    Write-Host '    supprime projet 2        supprimer le projet 2 (sessions incluses)' -ForegroundColor DarkYellow
    Write-Host '    supprime discord         supprimer les sessions dont le titre contient "discord"' -ForegroundColor White
    Write-Host '    tout supprimer           effacer toutes les sessions (confirmation forte)' -ForegroundColor DarkYellow
    Write-Host ''
    Write-Host '    detail 2                 voir le detail d''une session affichee' -ForegroundColor White
    Write-Host '    ouvre 2                  ouvrir le projet 2 dans OpenCode' -ForegroundColor White
    Write-Host '    ajoute C:\dossier        enregistrer un nouveau projet' -ForegroundColor White
    Write-Host ''
    Write-Host '    menu                     revenir a l''ancien menu numerote' -ForegroundColor DarkGray
    Write-Host '    quitter                  fermer l''outil' -ForegroundColor DarkGray
    Write-Host ''
    Write-Info 'Un simple numero affiche le detail (ou les sessions du projet).'
}

function Show-ProjetsListe {
    try { $projets = @(Get-Projects) }
    catch {
        Write-Erreur ("Lecture des projets impossible : {0}" -f $_.Exception.Message)
        return
    }

    $script:DerniersProjets = $projets
    $script:CtxProjet = $null
    $script:CtxSessions = @()

    if ($projets.Count -eq 0) {
        Write-Alerte 'Aucun projet enregistre pour le moment.'
        Write-Info 'Dites-moi "ajoute C:\chemin\du\projet" pour en enregistrer un.'
        return
    }

    Write-Host ''
    Write-Host ("  {0} projet(s) :" -f $projets.Count) -ForegroundColor Cyan
    $i = 0
    foreach ($p in $projets) {
        $i++
        $texteNb = '?'
        try {
            $nb = @(Get-Racines (Get-SessionsProjet -ProjectId $p.id)).Count
            if ($nb -eq 0) { $texteNb = 'aucune session' }
            elseif ($nb -eq 1) { $texteNb = '1 session' }
            else { $texteNb = "$nb sessions" }
        }
        catch { }

        Write-Host ''
        Write-Host ("  {0,2}. {1}" -f $i, (Get-ProjectNom $p)) -ForegroundColor White
        Write-Host ("      {0}" -f (Get-Tronque $p.canonical 62)) -ForegroundColor DarkGray
        Write-Host ("      {0}   derniere activite : {1}" -f $texteNb, (Format-Date $p.time.updated)) -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Info 'Dites "sessions 2" pour voir le detail du projet 2, "supprime 2" pour vider ses sessions,'
    Write-Info 'ou "supprime projet 2" pour supprimer le projet lui-meme.'
}

function Show-SessionsProjetConsole {
    param($Projet)

    try { $sessions = @(Get-SessionsProjet -ProjectId $Projet.id) }
    catch {
        Write-Erreur ("Lecture des sessions impossible : {0}" -f $_.Exception.Message)
        return
    }

    $racines = @(Get-Racines $sessions)
    $script:CtxProjet = $Projet
    $script:CtxSessions = $racines

    Write-Host ''
    Write-Host ('  Projet : ' + (Get-ProjectNom $Projet)) -ForegroundColor Cyan
    Write-Host ('  Dossier : ' + $Projet.canonical) -ForegroundColor DarkGray

    if ($racines.Count -eq 0) {
        Write-Alerte 'Aucune session dans ce projet.'
        Write-Info 'Pour en creer une, ouvrez ce projet dans OpenCode (commande "ouvre" suivie du numero).'
        return
    }

    Write-Host ("  {0} session(s) :" -f $racines.Count) -ForegroundColor Cyan
    $i = 0
    foreach ($s in $racines) {
        $i++
        $enfants = Get-NombreEnfants $sessions $s.id
        $suffixe = ''
        if ($enfants -gt 0) { $suffixe = "  (+$enfants sous-session(s))" }
        Write-Host ''
        Write-Host ("  {0,2}. {1}{2}" -f $i, (Get-Tronque (Get-TitreSession $s) 56), $suffixe) -ForegroundColor White
        Write-Host ("      {0}   {1}" -f (Format-Date $s.time.updated), $s.id) -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Info 'Dites "supprime 2" (ou "supprime 1,3") pour supprimer, "detail 2" pour le detail.'
}

function Resolve-Projet {
    param([string]$Texte)

    $projets = @($script:DerniersProjets)
    if ($projets.Count -eq 0) {
        try { $projets = @(Get-Projects); $script:DerniersProjets = $projets } catch { return $null }
    }
    if ($projets.Count -eq 0) {
        Write-Alerte 'Aucun projet enregistre.'
        return $null
    }

    $t = Convert-SansAccent $Texte
    $t = $t.Trim().Trim('"').Trim("'").TrimEnd('\')

    for ($k = 0; $k -lt 3; $k++) {
        $avant = $t
        $t = $t -replace '^(du|de la|de l''|des|de|le|la|les|l''|au|aux|mon|ma|mes)\s+', ''
        $t = $t -replace '^(projets?|dossier)\s+', ''
        if ($t -eq $avant) { break }
    }

    $n = 0
    if ([int]::TryParse($t, [ref]$n) -and $n -ge 1 -and $n -le $projets.Count) {
        return $projets[$n - 1]
    }

    if (-not $t) {
        Write-Alerte 'Precisez un numero de projet (voir "liste").'
        return $null
    }

    $trouves = @()
    foreach ($p in $projets) {
        $nom = Convert-SansAccent (Get-ProjectNom $p)
        $dossier = Convert-SansAccent (Split-Path -Path $p.canonical -Leaf)
        if ($nom -like "*$t*" -or $dossier -like "*$t*") { $trouves += $p }
    }

    if ($trouves.Count -eq 1) { return $trouves[0] }
    if ($trouves.Count -eq 0) {
        Write-Alerte ("Aucun projet ne correspond a '{0}'." -f $Texte)
        return $null
    }

    Write-Alerte ("Plusieurs projets correspondent a '{0}' :" -f $Texte)
    foreach ($p in $trouves) { Write-Info ('- ' + (Get-ProjectNom $p)) }
    Write-Info 'Utilisez le numero du projet (voir "liste").'
    return $null
}

function Chercher-Sessions {
    param([string]$Texte)

    $url = '/api/session?limit=1000&archived=false'
    if ($Texte) { $url += '&search=' + [uri]::EscapeDataString($Texte) }
    $reponse = Invoke-OcGet $url
    if (-not $reponse) { return @() }
    return @(Get-Racines @($reponse.data))
}

function Rechercher-SessionsConsole {
    param([string]$Texte)

    try { $trouvees = @(Chercher-Sessions $Texte) }
    catch {
        Write-Erreur ("Recherche impossible : {0}" -f $_.Exception.Message)
        return
    }

    if ($trouvees.Count -eq 0) {
        Write-Alerte ("Aucune session ne contient '{0}'." -f $Texte)
        Write-Info 'Tapez "aide" pour voir la liste des commandes.'
        return
    }

    try { $projets = @(Get-Projects) } catch { $projets = @() }
    $nomsProjets = @{}
    foreach ($p in $projets) { $nomsProjets[$p.id] = Get-ProjectNom $p }

    $script:CtxProjet = $null
    $script:CtxSessions = $trouvees

    Write-Host ''
    Write-Host ("  {0} session(s) contiennent '{1}' :" -f $trouvees.Count, $Texte) -ForegroundColor Cyan
    $i = 0
    foreach ($s in $trouvees) {
        $i++
        if ($i -gt 40) { break }
        $nomProjet = ''
        if ($nomsProjets.ContainsKey($s.projectID)) { $nomProjet = $nomsProjets[$s.projectID] }
        elseif ($s.location -and $s.location.directory) { $nomProjet = Split-Path -Leaf ([string]$s.location.directory) }
        else { $nomProjet = [string]$s.projectID }

        Write-Host ''
        Write-Host ("  {0,2}. {1}" -f $i, (Get-Tronque (Get-TitreSession $s) 56)) -ForegroundColor White
        Write-Host ("      {0}   [{1}]   {2}" -f (Format-Date $s.time.updated), (Get-Tronque $nomProjet 28), $s.id) -ForegroundColor DarkGray
    }
    if ($trouvees.Count -gt 40) { Write-Info ("... et {0} autre(s)" -f ($trouvees.Count - 40)) }

    Write-Host ''
    Write-Info 'Dites "supprime 1,3" pour supprimer des numeros de cette liste.'
}

function Detail-DepuisContexte {
    param([string]$Cible)

    if ($script:CtxSessions.Count -eq 0) {
        Write-Alerte 'Affichez d''abord une liste de sessions : "sessions 1" ou "cherche texte".'
        return
    }

    $n = 0
    if (-not [int]::TryParse($Cible.Trim(), [ref]$n) -or $n -lt 1 -or $n -gt $script:CtxSessions.Count) {
        Write-Alerte ("Numero invalide. Choisissez entre 1 et {0}." -f $script:CtxSessions.Count)
        return
    }
    Show-DetailSession $script:CtxSessions[$n - 1]
}

function Ouvrir-DepuisContexte {
    param([string]$Cible)

    if ($script:CtxSessions.Count -gt 0 -and $Cible -match '^\d+$') {
        $n = [int]$Cible
        if ($n -ge 1 -and $n -le $script:CtxSessions.Count) {
            $s = $script:CtxSessions[$n - 1]
            if ($s.location -and $s.location.directory) {
                Open-Projet ([pscustomobject]@{ canonical = $s.location.directory; id = $s.projectID })
                return
            }
        }
    }

    $p = Resolve-Projet $Cible
    if ($p) { Open-Projet $p }
}

function Supprimer-DepuisContexte {
    param([string]$Cible)

    $c = Convert-SansAccent $Cible
    $c = $c.Trim().Trim('"').Trim("'")

    if ($c -match '^(tout|tous|toutes|all|partout)$') {
        Purger-Tout
        $script:CtxProjet = $null
        $script:CtxSessions = @()
        Show-ProjetsListe
        return
    }

    if (-not $c) {
        Write-Alerte 'Precisez quoi supprimer : un numero (2), une liste (1,3), un titre, "projet 2" ou "tout".'
        return
    }

    # "supprime projet 2" / "supprime le projet discord" : suppression du projet entier.
    if ($c -match '^(?:(?:le|la|les)\s+|l''\s*)?projets?(?:\s+(.*))?$') {
        Supprimer-ProjetConsole -Cible ($Matches[1])
        return
    }

    $morceaux = @($c -split '[\s,;]+' | Where-Object { $_ })
    $queDesNumeros = $morceaux.Count -gt 0
    foreach ($m in $morceaux) { if ($m -notmatch '^\d+$') { $queDesNumeros = $false } }

    if ($queDesNumeros) {
        if ($script:CtxSessions.Count -gt 0) {
            $cibles = @()
            foreach ($m in $morceaux) {
                $n = [int]$m
                if ($n -ge 1 -and $n -le $script:CtxSessions.Count) { $cibles += $script:CtxSessions[$n - 1] }
            }
            if ($cibles.Count -eq 0) {
                Write-Alerte ("Aucun numero valide. Choisissez entre 1 et {0}." -f $script:CtxSessions.Count)
                return
            }

            if (-not (Confirm-Suppression -Cibles $cibles)) {
                Write-Info 'Suppression annulee.'
                return
            }

            Remove-SessionIds -Ids @($cibles | ForEach-Object { $_.id }) | Out-Null

            if ($script:CtxProjet) { Show-SessionsProjetConsole $script:CtxProjet }
            else { $script:CtxSessions = @() }
            return
        }

        # Pas de liste de sessions affichee : le numero designe un projet.
        $p = Resolve-Projet $morceaux[0]
        if ($p) { Supprimer-SessionsProjet $p | Out-Null }
        return
    }

    # Suppression par texte : on cherche dans les titres.
    try { $trouvees = @(Chercher-Sessions $Cible) }
    catch {
        Write-Erreur ("Recherche impossible : {0}" -f $_.Exception.Message)
        return
    }

    if ($trouvees.Count -eq 0) {
        Write-Alerte ("Aucune session ne contient '{0}'." -f $Cible)
        return
    }

    if ($trouvees.Count -eq 1) {
        if (Confirm-Suppression -Cibles $trouvees -Sessions $trouvees) {
            Remove-SessionIds -Ids @($trouvees[0].id) | Out-Null
        }
        else { Write-Info 'Suppression annulee.' }
        return
    }

    $script:CtxProjet = $null
    $script:CtxSessions = $trouvees
    Write-Alerte ("{0} sessions contiennent '{1}' :" -f $trouvees.Count, $Cible)
    $i = 0
    foreach ($s in $trouvees) {
        if ($i -ge 40) { break }
        $i++
        Write-Host ("   {0,2}. {1}" -f $i, (Get-Tronque (Get-TitreSession $s) 56)) -ForegroundColor White
    }
    if ($trouvees.Count -gt 40) { Write-Info ("... et {0} autre(s)" -f ($trouvees.Count - 40)) }
    Write-Host ''
    Write-Info 'Dites "supprime 1,3" pour supprimer les numeros ci-dessus.'
}

function Invoke-Commande {
    param([string]$Ligne)

    if ($null -eq $Ligne) { return $false }
    $brut = $Ligne.Trim()
    if (-not $brut) { Show-Aide; return $true }

    $texte = Convert-SansAccent $brut
    $texte = $texte -replace '^(peux-tu|peux tu|je veux|je voudrais|est-ce que je peux)\s+', ''
    $texte = $texte -replace '^(voir|montre-moi|montre|montrer|affiche|afficher|liste|list|affiches)\s+', ''

    if ($texte -match '^(quitter|quit|exit|q|fermer|bye|au revoir)$') { return $false }

    if ($texte -match '^(aide|help|h|\?|commandes?)$') { Show-Aide; return $true }

    if ($texte -match '^(menu|ancien menu|menu classique)$') {
        Start-MenuClassique
        Clear-Host
        Write-Logo
        Show-ProjetsListe
        return $true
    }

    if ($texte -match '^(projets?|liste|ls)$' -or $texte -match '^(les|mes|tous les|toutes les)\s+projets?$') {
        Show-ProjetsListe
        return $true
    }

    if ($texte -match '^sessions?\b\s*(.*)$') {
        $arg = $Matches[1].Trim()
        if (-not $arg) {
            if ($script:CtxProjet) { Show-SessionsProjetConsole $script:CtxProjet }
            else { Write-Alerte 'Precisez un projet : "sessions 2" ou "sessions nom-du-projet".' }
            return $true
        }
        $p = Resolve-Projet $arg
        if ($p) { Show-SessionsProjetConsole $p }
        return $true
    }

    if ($texte -match '^(cherche|chercher|recherche|rechercher|search|trouve|trouver)\b\s*(.*)$') {
        $arg = $Matches[2].Trim()
        if (-not $arg) { $arg = Read-Choix 'Texte a rechercher' }
        if ($arg) { Rechercher-SessionsConsole $arg }
        return $true
    }

    if ($texte -match '^(supprime|supprimer|suppr|sup|del|delete|efface|effacer|remove)\b\s*(.*)$') {
        Supprimer-DepuisContexte -Cible $Matches[2].Trim()
        return $true
    }

    if ($texte -match '^(detail|details|infos?|resume)\b\s*(.*)$') {
        $arg = $Matches[2].Trim()
        if (-not $arg) { $arg = Read-Choix 'Numero de la session' }
        if ($arg) { Detail-DepuisContexte -Cible $arg }
        return $true
    }

    if ($texte -match '^(ouvre|ouvrir|open|lance|lancer)\b\s*(.*)$') {
        $arg = $Matches[2].Trim()
        if (-not $arg) { $arg = Read-Choix 'Numero du projet' }
        if ($arg) { Ouvrir-DepuisContexte -Cible $arg }
        return $true
    }

    if ($texte -match '^(ajoute|ajouter|add|enregistre|enregistrer)\b\s*(.*)$') {
        Add-Projet -Chemin $Matches[2].Trim() | Out-Null
        $script:DerniersProjets = @()
        Show-ProjetsListe
        return $true
    }

    if ($texte -match '^(tout|purge|purger|vide|vider|nettoie|nettoyer)\b') {
        Purger-Tout
        $script:CtxProjet = $null
        $script:CtxSessions = @()
        Show-ProjetsListe
        return $true
    }

    if ($texte -match '^\d+$') {
        if ($script:CtxSessions.Count -gt 0) { Detail-DepuisContexte -Cible $texte }
        else {
            $p = Resolve-Projet $texte
            if ($p) { Show-SessionsProjetConsole $p }
        }
        return $true
    }

    # Dernier recours : on cherche le texte dans les titres de sessions.
    Rechercher-SessionsConsole $brut
    return $true
}

function Start-Console {
    Clear-Host
    Write-Logo
    Write-Host ''
    Write-Host '       Gestion des projets et des sessions OpenCode' -ForegroundColor White
    Write-Host ('  ' + ('-' * 66)) -ForegroundColor DarkCyan
    Write-Host ''
    Write-Host '  Ecrivez ce que vous voulez faire, en francais :' -ForegroundColor Gray
    Write-Host '  "liste", "sessions 2", "supprime 3", "cherche discord"...' -ForegroundColor Gray
    Write-Host '  Tapez "aide" pour voir toutes les commandes, "quitter" pour fermer.' -ForegroundColor Gray

    Show-ProjetsListe

    while ($true) {
        $ligne = Read-Commande
        if ($null -eq $ligne) { break }
        if (-not (Invoke-Commande $ligne)) { break }
    }
    Clear-Host
}

function Start-MenuClassique {
    while ($true) {
        Show-Menu
        $choix = Read-Choix

        if ($null -eq $choix) { Clear-Host; return }

        switch ($choix) {
            '1' { Show-Projets }
            '2' { Add-Projet | Out-Null; Write-Attente }
            '3' {
                $p = Select-Projet 'Ouvrir un projet dans OpenCode'
                if ($p) { Open-Projet $p; Write-Attente }
            }
            '4' {
                $p = Select-Projet 'Supprimer un projet (ses sessions seront aussi supprimees)'
                if ($p) { Supprimer-ProjetConsole -Projet $p }
            }
            '5' {
                $p = Select-Projet 'Gerer un projet : voir / supprimer ses sessions'
                if ($p) { Gerer-Projet $p }
            }
            '6' { Rechercher-Et-Supprimer }
            '7' { Supprimer-ToutesSessionsProjet }
            '8' { Purger-Tout }
            '9' { Show-Infos }
            '0' { Clear-Host; return }
            ''  { }
            default {
                Write-Alerte 'Choix invalide.'
                Start-Sleep -Milliseconds 600
            }
        }
    }
}

# ---------------------------------------------------------------------------
#  Interface graphique (WinForms)
# ---------------------------------------------------------------------------

function Initialize-GuiStyle {
    $script:UiFond        = [System.Drawing.Color]::FromArgb(22, 22, 24)
    $script:UiFond2       = [System.Drawing.Color]::FromArgb(31, 31, 35)
    $script:UiFond3       = [System.Drawing.Color]::FromArgb(43, 43, 49)
    $script:UiTexte       = [System.Drawing.Color]::FromArgb(232, 232, 238)
    $script:UiTexteDim    = [System.Drawing.Color]::FromArgb(150, 150, 160)
    $script:UiAccent      = [System.Drawing.Color]::FromArgb(0, 170, 225)
    $script:UiAccentFonce = [System.Drawing.Color]::FromArgb(0, 110, 160)
    $script:UiRouge       = [System.Drawing.Color]::FromArgb(205, 70, 70)
    $script:UiVert        = [System.Drawing.Color]::FromArgb(90, 200, 130)

    $script:UiPolice      = New-Object System.Drawing.Font('Segoe UI', 9)
    $script:UiPoliceGras  = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $script:UiPoliceTitre = New-Object System.Drawing.Font('Segoe UI', 17, [System.Drawing.FontStyle]::Bold)
    $script:UiPoliceLogo  = New-Object System.Drawing.Font('Consolas', 8.5, [System.Drawing.FontStyle]::Bold)

    $script:LogoAscii = @'
   ___                    ____          _
  / _ \ _ __   ___ _ __  / ___|___   __| | ___
 | | | | '_ \ / _ \ '_ \| |   / _ \ / _` |/ _ \
 | |_| | |_) |  __/ | | | |__| (_) | (_| |  __/
  \___/| .__/ \___|_| |_|\____\___/ \__,_|\___|
       |_|
'@
}

function New-UiBouton {
    param(
        [string]$Texte,
        [int]$Largeur = 140,
        [switch]$Accent,
        [switch]$Danger
    )

    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Texte
    $b.Width = $Largeur
    $b.Height = 32
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 1
    $b.BackColor = $script:UiFond3
    $b.ForeColor = $script:UiTexte
    $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(72, 72, 80)
    $b.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(56, 56, 64)
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.Font = $script:UiPolice

    if ($Accent) {
        $b.BackColor = $script:UiAccentFonce
        $b.ForeColor = [System.Drawing.Color]::White
        $b.FlatAppearance.BorderColor = $script:UiAccent
        $b.FlatAppearance.MouseOverBackColor = $script:UiAccent
    }
    if ($Danger) {
        $b.ForeColor = [System.Drawing.Color]::FromArgb(255, 160, 160)
        $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(140, 60, 60)
    }

    return $b
}

function New-UiGrille {
    $g = New-Object System.Windows.Forms.DataGridView
    $g.Dock = 'Fill'
    $g.Margin = New-Object System.Windows.Forms.Padding(0)
    $g.BackgroundColor = $script:UiFond
    $g.BorderStyle = 'None'
    $g.AutoGenerateColumns = $false
    $g.AllowUserToAddRows = $false
    $g.AllowUserToDeleteRows = $false
    $g.AllowUserToResizeRows = $false
    $g.AllowUserToResizeColumns = $false
    $g.RowHeadersVisible = $false
    $g.EnableHeadersVisualStyles = $false
    $g.ColumnHeadersBorderStyle = 'Single'
    $g.ColumnHeadersHeight = 30
    $g.RowTemplate.Height = 32
    $g.GridColor = [System.Drawing.Color]::FromArgb(48, 48, 55)
    $g.CellBorderStyle = 'SingleHorizontal'

    $g.ColumnHeadersDefaultCellStyle.BackColor = $script:UiFond3
    $g.ColumnHeadersDefaultCellStyle.ForeColor = $script:UiTexteDim
    $g.ColumnHeadersDefaultCellStyle.SelectionBackColor = $script:UiFond3
    $g.ColumnHeadersDefaultCellStyle.Font = $script:UiPoliceGras
    $g.ColumnHeadersDefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(8, 0, 4, 0)

    $g.DefaultCellStyle.BackColor = $script:UiFond2
    $g.DefaultCellStyle.ForeColor = $script:UiTexte
    $g.DefaultCellStyle.SelectionBackColor = $script:UiAccentFonce
    $g.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
    $g.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(8, 0, 4, 0)
    $g.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(27, 27, 31)

    return $g
}

function New-UiColonne {
    param(
        [string]$Titre,
        [int]$Largeur = 0,
        [int]$Poids = 100,
        [string]$Alignement = 'MiddleLeft'
    )

    $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $c.HeaderText = $Titre
    $c.SortMode = 'NotSortable'
    $c.ReadOnly = $true
    $c.DefaultCellStyle.Alignment = $Alignement
    if ($Largeur -gt 0) {
        $c.AutoSizeMode = 'None'
        $c.Width = $Largeur
    }
    else {
        $c.AutoSizeMode = 'Fill'
        $c.FillWeight = $Poids
    }
    return $c
}

function Set-GuiStatut {
    param([string]$Texte, [string]$Type = 'info')
    if (-not $script:GuiStatut) { return }

    $couleur = $script:UiTexteDim
    if ($Type -eq 'ok') { $couleur = $script:UiVert }
    elseif ($Type -eq 'erreur') { $couleur = [System.Drawing.Color]::FromArgb(255, 135, 135) }
    elseif ($Type -eq 'action') { $couleur = $script:UiAccent }

    $script:GuiStatut.Text = '  ' + $Texte
    $script:GuiStatut.ForeColor = $couleur
}

function Set-GuiBoutonsSessions {
    param([bool]$Actifs)
    foreach ($b in @($script:GuiBtnNouvelle, $script:GuiBtnSupprimer, $script:GuiBtnToutSupprimer, $script:GuiBtnDetail)) {
        if ($b) { $b.Enabled = $Actifs }
    }
}

function Invoke-GuiAction {
    param([scriptblock]$Action)
    try { & $Action }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            ("Une erreur est survenue :`n`n" + $_.Exception.Message),
            'Gestion OpenCode', 'OK', 'Error') | Out-Null
    }
}

function Update-GuiProjets {
    param([string]$IdASelectionner = '')

    $g = $script:GuiGrilleProjets
    if (-not $g) { return }

    $curseur = [System.Windows.Forms.Cursor]::Current
    [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
    $ligneCible = -1
    $scrollProjets = 0
    try {
        try { if ($g.FirstDisplayedScrollingRowIndex -gt 0) { $scrollProjets = $g.FirstDisplayedScrollingRowIndex } } catch { }
        try { $projets = @(Get-Projects) }
        catch {
            Set-GuiStatut ('Lecture des projets impossible : ' + $_.Exception.Message) 'erreur'
            return
        }

        $script:GuiProjets = $projets
        if ($script:GuiTitreProjets) {
            $script:GuiTitreProjets.Text = ('PROJETS   —   {0}' -f $projets.Count)
        }
        $script:GuiRemplissage = $true
        try {
            $g.Rows.Clear()
            foreach ($p in $projets) {
                $texteNb = '?'
                try { $texteNb = [string](@(Get-Racines (Get-SessionsProjet -ProjectId $p.id)).Count) } catch { }
                $idx = $g.Rows.Add((Get-ProjectNom $p), $texteNb, (Format-Date $p.time.updated))
                $g.Rows[$idx].Tag = $p
                $g.Rows[$idx].Cells[0].ToolTipText = $p.canonical
                $g.Rows[$idx].Cells[1].Style.Alignment = 'MiddleCenter'
                $g.Rows[$idx].Cells[2].Style.ForeColor = $script:UiTexteDim
            }

            if ($IdASelectionner) {
                for ($i = 0; $i -lt $g.Rows.Count; $i++) {
                    $p = $g.Rows[$i].Tag
                    if ($p -and $p.id -eq $IdASelectionner) { $ligneCible = $i; break }
                }
            }
            if ($ligneCible -lt 0 -and $g.Rows.Count -gt 0) { $ligneCible = 0 }

            if ($ligneCible -ge 0) {
                $g.ClearSelection()
                $g.Rows[$ligneCible].Selected = $true
                $g.CurrentCell = $g.Rows[$ligneCible].Cells[0]
                if ($scrollProjets -gt 0) {
                    try {
                        $max = $g.Rows.Count - 1
                        if ($scrollProjets -gt $max) { $scrollProjets = $max }
                        $g.FirstDisplayedScrollingRowIndex = $scrollProjets
                    }
                    catch { }
                }
            }
        }
        finally { $script:GuiRemplissage = $false }

        if ($ligneCible -ge 0) {
            Update-GuiSessions $g.Rows[$ligneCible].Tag
        }
        else {
            Update-GuiSessions $null
            Set-GuiStatut 'Aucun projet enregistre. Utilisez « Ajouter un projet ».  ' 'info'
        }

        if ($projets.Count -gt 0) {
            $dossier = ''
            if ($script:GuiProjetCourant) { $dossier = '  —  ' + (Get-Tronque $script:GuiProjetCourant.canonical 70) }
            Set-GuiStatut ("{0} projet(s){1}" -f $projets.Count, $dossier) 'info'
        }
    }
    finally {
        [System.Windows.Forms.Cursor]::Current = $curseur
    }
}

function Update-GuiSessions {
    param($Projet)

    $g = $script:GuiGrilleSessions
    if (-not $g) { return }

    $ancienId = ''
    if ($script:GuiProjetCourant) { $ancienId = [string]$script:GuiProjetCourant.id }
    $nouvelId = ''
    if ($Projet) { $nouvelId = [string]$Projet.id }

    $selectionSession = ''
    $scrollSessions = 0
    if ($Projet -and $ancienId -eq $nouvelId) {
        $ligneAvant = $g.CurrentRow
        if ($ligneAvant -and $ligneAvant.Tag) { $selectionSession = [string]$ligneAvant.Tag.id }
        try {
            if ($g.FirstDisplayedScrollingRowIndex -gt 0) { $scrollSessions = $g.FirstDisplayedScrollingRowIndex }
        }
        catch { }
    }

    $script:GuiProjetCourant = $Projet
    $script:GuiSessions = @()
    $script:GuiSessionsBrutes = @()
    $script:GuiRemplissage = $true
    try { $g.Rows.Clear() } finally { $script:GuiRemplissage = $false }

    if (-not $Projet) {
        $script:GuiTitreSessions.Text = 'SESSIONS'
        Set-GuiBoutonsSessions $false
        if ($script:GuiBtnSupprimerProjet) { $script:GuiBtnSupprimerProjet.Enabled = $false }
        return
    }

    if ($script:GuiBtnSupprimerProjet) { $script:GuiBtnSupprimerProjet.Enabled = $true }

    $script:GuiTitreSessions.Text = 'SESSIONS  —  ' + (Get-ProjectNom $Projet)

    $curseur = [System.Windows.Forms.Cursor]::Current
    [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        try { $sessions = @(Get-SessionsProjet -ProjectId $Projet.id) }
        catch {
            Set-GuiStatut ('Lecture des sessions impossible : ' + $_.Exception.Message) 'erreur'
            Set-GuiBoutonsSessions $false
            return
        }

        # Les sessions qu'on vient de supprimer ne doivent jamais reapparaitre,
        # meme si le serveur renvoie encore une liste en retard.
        if (@($script:GuiSessionsSupprimees).Count -gt 0) {
            $sessions = @($sessions | Where-Object { $script:GuiSessionsSupprimees -notcontains [string]$_.id })
        }

        $script:GuiSessionsBrutes = $sessions
        $racines = @(Get-Racines $sessions)
        $script:GuiSessions = $racines

        $script:GuiRemplissage = $true
        try {
            foreach ($s in $racines) {
                $enfants = Get-NombreEnfants $sessions $s.id
                $idx = $g.Rows.Add((Get-TitreSession $s), [string]$enfants, (Format-Date $s.time.updated))
                $g.Rows[$idx].Tag = $s
                $g.Rows[$idx].Cells[0].ToolTipText = (Get-TitreSession $s) + "`n" + $s.id
                $g.Rows[$idx].Cells[1].Style.Alignment = 'MiddleCenter'
                $g.Rows[$idx].Cells[2].Style.ForeColor = $script:UiTexteDim
                if ($enfants -gt 0) { $g.Rows[$idx].Cells[1].Style.ForeColor = $script:UiAccent }
            }
            if ($g.Rows.Count -gt 0) {
                $ligneSel = 0
                if ($selectionSession) {
                    for ($i = 0; $i -lt $g.Rows.Count; $i++) {
                        $t = $g.Rows[$i].Tag
                        if ($t -and [string]$t.id -eq $selectionSession) { $ligneSel = $i; break }
                    }
                }
                $g.ClearSelection()
                $g.Rows[$ligneSel].Selected = $true
                $g.CurrentCell = $g.Rows[$ligneSel].Cells[0]
                if ($scrollSessions -gt 0) {
                    try {
                        $max = $g.Rows.Count - 1
                        if ($scrollSessions -gt $max) { $scrollSessions = $max }
                        $g.FirstDisplayedScrollingRowIndex = $scrollSessions
                    }
                    catch { }
                }
            }
        }
        finally { $script:GuiRemplissage = $false }

        Set-GuiBoutonsSessions ($racines.Count -gt 0)
        if ($racines.Count -eq 0) {
            Set-GuiStatut 'Aucune session dans ce projet.' 'info'
        }
        else {
            Set-GuiStatut ("{0} session(s) — {1} sous-session(s)" -f $racines.Count, ($sessions.Count - $racines.Count)) 'info'
        }
    }
    finally {
        [System.Windows.Forms.Cursor]::Current = $curseur
    }
}

function Get-GuiSignature {
    # Empreinte de l'etat affiche : evite de reconstruire les grilles a chaque
    # battement du minuteur quand rien n'a change.
    $parties = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($p in @(Get-Projects)) {
            $parties.Add(('P|{0}|{1}' -f $p.id, $p.time.updated))
            if ($script:GuiProjetCourant -and $p.id -eq $script:GuiProjetCourant.id) {
                foreach ($s in @(Get-SessionsProjet -ProjectId $p.id)) {
                    $parties.Add(('S|{0}|{1}|{2}' -f $s.id, $s.title, $s.time.updated))
                }
            }
        }
    }
    catch {
        return ''
    }
    return ($parties -join "`n")
}

function Update-GuiAutoRefresh {
    # Rafraichit seulement si l'API signale un changement. Les suppressions
    # faites dans OpenCode disparaissent donc sans action de l'utilisateur.
    if (-not $script:GuiPret) { return }
    if ($script:GuiRafraichissement) { return }
    if ($script:GuiForm -and -not $script:GuiForm.Visible) { return }

    $script:GuiRafraichissement = $true
    try {
        $signature = Get-GuiSignature
        if (-not $signature) { return }
        if ($signature -eq $script:GuiSignature) { return }

        $id = ''
        if ($script:GuiProjetCourant) { $id = [string]$script:GuiProjetCourant.id }

        Update-GuiProjets -IdASelectionner $id

        $script:GuiSignature = $signature
    }
    catch { }
    finally { $script:GuiRafraichissement = $false }
}

function Show-GuiConfirmation {
    param(
        [object[]]$Lignes,
        [string]$Contexte = ''
    )

    # Test automatise : on ne bloque pas sur la boite de dialogue.
    if ($env:OC_GESTION_SELFTEST_AUTO) { return $true }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Confirmer la suppression'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.StartPosition = 'CenterParent'
    $dlg.BackColor = $script:UiFond
    $dlg.ForeColor = $script:UiTexte
    $dlg.Font = $script:UiPolice
    $dlg.ClientSize = New-Object System.Drawing.Size(580, 440)

    $titre = New-Object System.Windows.Forms.Label
    $titre.Text = ("Supprimer {0} session(s) ?" -f $Lignes.Count)
    $titre.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
    $titre.ForeColor = [System.Drawing.Color]::FromArgb(255, 145, 145)
    $titre.AutoSize = $true
    $titre.Location = New-Object System.Drawing.Point(22, 18)
    $dlg.Controls.Add($titre)

    $info = New-Object System.Windows.Forms.Label
    $info.Text = 'Cette action est définitive. Les sous-sessions sont supprimées avec leur session parente.'
    $info.ForeColor = $script:UiTexteDim
    $info.AutoSize = $false
    $info.Size = New-Object System.Drawing.Size(536, 34)
    $info.Location = New-Object System.Drawing.Point(22, 50)
    $dlg.Controls.Add($info)

    $yListe = 88
    if ($Contexte) {
        $ctx = New-Object System.Windows.Forms.Label
        $ctx.Text = $Contexte
        $ctx.ForeColor = $script:UiAccent
        $ctx.AutoSize = $false
        $ctx.Size = New-Object System.Drawing.Size(536, 20)
        $ctx.Location = New-Object System.Drawing.Point(22, 88)
        $dlg.Controls.Add($ctx)
        $yListe = 112
    }

    $liste = New-Object System.Windows.Forms.ListBox
    $liste.Location = New-Object System.Drawing.Point(22, $yListe)
    $liste.Size = New-Object System.Drawing.Size(536, 440 - $yListe - 76)
    $liste.BackColor = $script:UiFond2
    $liste.ForeColor = $script:UiTexte
    $liste.BorderStyle = 'FixedSingle'
    $liste.Font = $script:UiPolice
    foreach ($l in $Lignes) {
        $texte = '  ' + (Get-Tronque ([string]$l.Titre) 58)
        if ($l.Enfants -gt 0) { $texte += ('   (+{0} sous-session(s))' -f $l.Enfants) }
        [void]$liste.Items.Add($texte)
    }
    $dlg.Controls.Add($liste)

    $btnAnnuler = New-UiBouton -Texte 'Annuler' -Largeur 120
    $btnAnnuler.Location = New-Object System.Drawing.Point(300, 440 - 48)
    $btnAnnuler.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($btnAnnuler)

    $btnOk = New-UiBouton -Texte 'Supprimer définitivement' -Largeur 210 -Danger
    $btnOk.Location = New-Object System.Drawing.Point(430, 440 - 48)
    $btnOk.Add_Click({ $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK })
    $dlg.Controls.Add($btnOk)

    $dlg.CancelButton = $btnAnnuler

    $resultat = $dlg.ShowDialog($script:GuiForm)
    $dlg.Dispose()
    return [bool]($resultat -eq [System.Windows.Forms.DialogResult]::OK)
}

function Remove-GuiSessions {
    param([object[]]$Sessions)

    $ok = 0
    $erreurs = @()
    $ids = @()
    foreach ($s in $Sessions) {
        try {
            Invoke-OcApi -ArgListe @('api', 'delete', "/api/session/$($s.id)") | Out-Null
            $ok++
            $ids += [string]$s.id
        }
        catch {
            $erreurs += ((Get-TitreSession $s) + ' : ' + $_.Exception.Message)
        }
    }
    return [pscustomobject]@{ Ok = $ok; Erreurs = $erreurs; Ids = $ids }
}

function Supprimer-GuiSessions {
    param(
        [object[]]$Cibles,
        $SessionsCompletes,
        [string]$Contexte = ''
    )

    if (-not $Cibles -or $Cibles.Count -eq 0) { return }

    $lignes = @()
    foreach ($s in $Cibles) {
        $enfants = 0
        if ($SessionsCompletes) { $enfants = Get-NombreEnfants $SessionsCompletes $s.id }
        $lignes += [pscustomobject]@{ Titre = (Get-TitreSession $s); Enfants = $enfants }
    }

    if (-not (Show-GuiConfirmation -Lignes $lignes -Contexte $Contexte)) { return }

    $idCourant = ''
    if ($script:GuiProjetCourant) { $idCourant = [string]$script:GuiProjetCourant.id }

    [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
    try { $resultat = Remove-GuiSessions -Sessions $Cibles }
    finally { [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default }

    foreach ($id in @($resultat.Ids)) {
        if ($script:GuiSessionsSupprimees -notcontains $id) { $script:GuiSessionsSupprimees += $id }
    }

    # On retire les lignes tout de suite : meme si l'actualisation echoue ou
    # renvoie une liste en retard, ce qui a ete supprime disparait de l'ecran.
    $grille = $script:GuiGrilleSessions
    if ($grille) {
        $script:GuiRemplissage = $true
        try {
            for ($i = $grille.Rows.Count - 1; $i -ge 0; $i--) {
                $t = $grille.Rows[$i].Tag
                if ($t -and ($script:GuiSessionsSupprimees -contains [string]$t.id)) {
                    $grille.Rows.RemoveAt($i)
                }
            }
        }
        finally { $script:GuiRemplissage = $false }

        $script:GuiSessions = @($script:GuiSessions | Where-Object { $script:GuiSessionsSupprimees -notcontains [string]$_.id })
        $script:GuiSessionsBrutes = @($script:GuiSessionsBrutes | Where-Object { $script:GuiSessionsSupprimees -notcontains [string]$_.id })
        Set-GuiBoutonsSessions ($script:GuiSessions.Count -gt 0)
    }

    Update-GuiProjets -IdASelectionner $idCourant

    if ($resultat.Ok -gt 0) {
        Set-GuiStatut ("{0} session(s) supprimée(s)." -f $resultat.Ok) 'ok'
    }
    if ($resultat.Erreurs.Count -gt 0) {
        $details = ($resultat.Erreurs | Select-Object -First 6) -join "`n"
        [System.Windows.Forms.MessageBox]::Show(
            ("Certaines sessions n'ont pas pu être supprimées :`n`n" + $details + "`n`nFermez la session dans OpenCode puis réessayez."),
            'Gestion OpenCode', 'OK', 'Warning') | Out-Null
    }
}

function Supprimer-GuiSelection {
    $g = $script:GuiGrilleSessions
    if (-not $g) { return }

    $cibles = @()
    foreach ($row in $g.SelectedRows) {
        if ($row.Tag) { $cibles += $row.Tag }
    }
    if ($cibles.Count -eq 0 -and $g.CurrentRow -and $g.CurrentRow.Tag) {
        $cibles = @($g.CurrentRow.Tag)
    }
    if ($cibles.Count -eq 0) { return }

    $contexte = ''
    if ($script:GuiProjetCourant) { $contexte = 'Projet : ' + (Get-ProjectNom $script:GuiProjetCourant) }
    Supprimer-GuiSessions -Cibles $cibles -SessionsCompletes $script:GuiSessionsBrutes -Contexte $contexte
}

function Supprimer-GuiSessionsProjet {
    param($Projet)
    if (-not $Projet) { return }

    try {
        $sessions = @(Get-SessionsProjet -ProjectId $Projet.id)
        $sessions += @(Get-SessionsProjetArchivees -ProjectId $Projet.id)
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            ("Lecture des sessions impossible :`n" + $_.Exception.Message),
            'Gestion OpenCode', 'OK', 'Error') | Out-Null
        return
    }

    $racines = @(Get-Racines $sessions)
    if ($racines.Count -eq 0) {
        Set-GuiStatut 'Ce projet ne contient aucune session.' 'info'
        return
    }

    Supprimer-GuiSessions -Cibles $racines -SessionsCompletes $sessions -Contexte ('Tout le projet : ' + (Get-ProjectNom $Projet))
}

function Show-GuiConfirmationProjet {
    param($Projet, $Sessions)

    if ($env:OC_GESTION_SELFTEST_AUTO) { return $true }

    $nom = Get-ProjectNom $Projet
    $nbSessions = 0
    $nbRacines = 0
    if ($Sessions) {
        $nbSessions = @($Sessions).Count
        $nbRacines = @(Get-Racines $Sessions).Count
    }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Supprimer le projet'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.StartPosition = 'CenterParent'
    $dlg.BackColor = $script:UiFond
    $dlg.ForeColor = $script:UiTexte
    $dlg.Font = $script:UiPolice
    $dlg.ClientSize = New-Object System.Drawing.Size(600, 300)

    $titre = New-Object System.Windows.Forms.Label
    $titre.Text = 'Supprimer ce projet ?'
    $titre.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
    $titre.ForeColor = [System.Drawing.Color]::FromArgb(255, 145, 145)
    $titre.AutoSize = $true
    $titre.Location = New-Object System.Drawing.Point(22, 18)
    $dlg.Controls.Add($titre)

    $lblNom = New-Object System.Windows.Forms.Label
    $lblNom.Text = $nom
    $lblNom.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $lblNom.ForeColor = [System.Drawing.Color]::White
    $lblNom.AutoSize = $false
    $lblNom.Size = New-Object System.Drawing.Size(556, 26)
    $lblNom.Location = New-Object System.Drawing.Point(22, 52)
    $dlg.Controls.Add($lblNom)

    $lblChemin = New-Object System.Windows.Forms.Label
    $lblChemin.Text = [string]$Projet.canonical
    $lblChemin.ForeColor = $script:UiTexteDim
    $lblChemin.AutoSize = $false
    $lblChemin.Size = New-Object System.Drawing.Size(556, 20)
    $lblChemin.Location = New-Object System.Drawing.Point(22, 80)
    $dlg.Controls.Add($lblChemin)

    $info = New-Object System.Windows.Forms.Label
    $texteSessions = 'Ce projet ne contient aucune session.'
    if ($nbSessions -eq 1) { $texteSessions = '1 session sera aussi supprimee.' }
    elseif ($nbSessions -gt 1) { $texteSessions = ("{0} sessions seront aussi supprimees." -f $nbSessions) }
    if ($nbSessions -gt $nbRacines -and $nbRacines -gt 0) {
        $texteSessions += (" (dont {0} sous-session(s))" -f ($nbSessions - $nbRacines))
    }
    $info.Text = $texteSessions
    $info.ForeColor = $script:UiTexte
    $info.AutoSize = $false
    $info.Size = New-Object System.Drawing.Size(556, 22)
    $info.Location = New-Object System.Drawing.Point(22, 116)
    $dlg.Controls.Add($info)

    $note = New-Object System.Windows.Forms.Label
    $note.Text = "Le projet sera retire de la liste OpenCode.`nLe dossier sur le disque n'est PAS supprime : vos fichiers restent intacts."
    $note.ForeColor = $script:UiVert
    $note.AutoSize = $false
    $note.Size = New-Object System.Drawing.Size(556, 44)
    $note.Location = New-Object System.Drawing.Point(22, 146)
    $dlg.Controls.Add($note)

    $btnAnnuler = New-UiBouton -Texte 'Annuler' -Largeur 120
    $btnAnnuler.Location = New-Object System.Drawing.Point(310, 240)
    $btnAnnuler.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($btnAnnuler)

    $btnOk = New-UiBouton -Texte 'Supprimer le projet' -Largeur 170 -Danger
    $btnOk.Location = New-Object System.Drawing.Point(440, 240)
    $btnOk.Add_Click({ $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK })
    $dlg.Controls.Add($btnOk)

    $dlg.CancelButton = $btnAnnuler

    $resultat = $dlg.ShowDialog($script:GuiForm)
    $dlg.Dispose()
    return [bool]($resultat -eq [System.Windows.Forms.DialogResult]::OK)
}

function Supprimer-ProjetGui {
    param($Projet)

    if (-not $Projet) { return }

    $nom = Get-ProjectNom $Projet

    try { $sessions = @(Get-SessionsProjet -ProjectId $Projet.id) }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            ("Lecture des sessions impossible :`n`n" + $_.Exception.Message),
            'Gestion OpenCode', 'OK', 'Error') | Out-Null
        return
    }

    $archiveesAvant = @()
    try { $archiveesAvant = @(Get-SessionsProjetArchivees -ProjectId $Projet.id) } catch { }

    if (-not (Show-GuiConfirmationProjet -Projet $Projet -Sessions (@($sessions) + @($archiveesAvant)))) { return }

    $erreurs = @()
    $supprimees = 0

    [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $racines = @(Get-Racines $sessions)
        if ($racines.Count -gt 0) {
            $resultat = Remove-GuiSessions -Sessions $racines
            $supprimees = $resultat.Ok
            $erreurs = @($resultat.Erreurs)
        }

        # Les sessions archivees restent en base et bloqueraient la suppression.
        if ($erreurs.Count -eq 0) {
            try {
                $resultatArchivees = Remove-SessionsArchiveesProjet -ProjectId $Projet.id
                $supprimees += $resultatArchivees.Ok
                if ($resultatArchivees.Erreurs.Count -gt 0) {
                    $erreurs += @($resultatArchivees.Erreurs)
                }
            }
            catch {
                $erreurs += ('Nettoyage des sessions archivees : ' + $_.Exception.Message)
            }
        }

        if ($erreurs.Count -eq 0) {
            Remove-ProjetBase -ProjectId $Projet.id | Out-Null
        }
    }
    catch {
        $erreurs += $_.Exception.Message
    }
    finally {
        [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
    }

    $encoreLa = $false
    try {
        $encoreLa = @(Get-Projects | Where-Object { $_.id -eq $Projet.id }).Count -gt 0
    }
    catch { }

    Update-GuiProjets

    if ($erreurs.Count -gt 0) {
        $details = ($erreurs | Select-Object -First 6) -join "`n"
        if ($env:OC_GESTION_SELFTEST_AUTO) { $script:GuiSelfTestErreurs = $details }
        [System.Windows.Forms.MessageBox]::Show(
            ("La suppression du projet a echoue :`n`n" + $details + "`n`nSi une fenetre OpenCode est ouverte dans ce dossier, fermez-la puis reessayez."),
            'Gestion OpenCode', 'OK', 'Warning') | Out-Null
        return
    }

    if ($encoreLa) {
        # OpenCode l'a recree (fenetre ou client actif dans ce dossier).
        Set-GuiStatut (("{0} : OpenCode l'a recree (dossier ouvert). Relancez la suppression apres avoir ferme OpenCode." -f $nom)) 'info'
        return
    }

    Set-GuiStatut (("Projet supprime : {0}  ({1} session(s) effacee(s))" -f $nom, $supprimees)) 'ok'
}

function Show-GuiSaisie {
    param(
        [string]$Titre,
        [string]$Invite,
        [string]$Valeur = '',
        [switch]$Dossier
    )

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Titre
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.StartPosition = 'CenterParent'
    $dlg.BackColor = $script:UiFond
    $dlg.ForeColor = $script:UiTexte
    $dlg.Font = $script:UiPolice
    $dlg.ClientSize = New-Object System.Drawing.Size(640, 170)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Invite
    $lbl.AutoSize = $false
    $lbl.Size = New-Object System.Drawing.Size(596, 22)
    $lbl.Location = New-Object System.Drawing.Point(22, 18)
    $dlg.Controls.Add($lbl)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Text = $Valeur
    $txt.Location = New-Object System.Drawing.Point(22, 46)
    $txt.Size = New-Object System.Drawing.Size(596, 26)
    $txt.BackColor = $script:UiFond2
    $txt.ForeColor = $script:UiTexte
    $txt.BorderStyle = 'FixedSingle'
    $dlg.Controls.Add($txt)

    $boutons = @()

    if ($Dossier) {
        $btnParcourir = New-UiBouton -Texte 'Parcourir...' -Largeur 110
        $btnParcourir.Location = New-Object System.Drawing.Point(22, 92)
        $btnParcourir.Add_Click({
            $fb = New-Object System.Windows.Forms.FolderBrowserDialog
            $fb.Description = 'Choisissez le dossier du projet'
            $fb.ShowNewFolderButton = $true
            if ($fb.ShowDialog($dlg) -eq [System.Windows.Forms.DialogResult]::OK) {
                $txt.Text = $fb.SelectedPath
            }
            $fb.Dispose()
        })
        $dlg.Controls.Add($btnParcourir)
        $boutons += $btnParcourir
    }

    $btnAnnuler = New-UiBouton -Texte 'Annuler' -Largeur 110
    $btnAnnuler.Location = New-Object System.Drawing.Point(396, 120)
    $btnAnnuler.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($btnAnnuler)

    $btnOk = New-UiBouton -Texte 'Valider' -Largeur 110 -Accent
    $btnOk.Location = New-Object System.Drawing.Point(514, 120)
    $btnOk.Add_Click({
        if ($txt.Text.Trim()) { $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK }
    })
    $dlg.Controls.Add($btnOk)

    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnAnnuler

    $resultat = $dlg.ShowDialog($script:GuiForm)
    $valeur = $txt.Text.Trim()
    $dlg.Dispose()

    if ($resultat -eq [System.Windows.Forms.DialogResult]::OK) { return $valeur }
    return $null
}

function Add-ProjetGui {
    param([string]$Chemin = '')

    if (-not $Chemin) {
        $Chemin = Show-GuiSaisie -Titre 'Ajouter un projet' -Invite 'Dossier à enregistrer dans OpenCode :' -Dossier
    }
    if (-not $Chemin) { return $null }

    $Chemin = $Chemin.Trim().Trim('"').Trim("'")
    try { $Chemin = [Environment]::ExpandEnvironmentVariables($Chemin) } catch { }

    if (-not (Test-Path -LiteralPath $Chemin -PathType Container)) {
        [System.Windows.Forms.MessageBox]::Show(
            ("Le dossier n'existe pas :`n" + $Chemin),
            'Gestion OpenCode', 'OK', 'Warning') | Out-Null
        return $null
    }

    $resolu = (Resolve-Path -LiteralPath $Chemin).ProviderPath

    try { $projets = @(Get-Projects) } catch { $projets = @() }
    $existant = $projets |
        Where-Object { $_.canonical -and ($_.canonical.TrimEnd('\') -ieq $resolu.TrimEnd('\')) } |
        Select-Object -First 1

    if ($existant) {
        Update-GuiProjets -IdASelectionner $existant.id
        Set-GuiStatut ('Déjà enregistré : ' + (Get-ProjectNom $existant)) 'action'
        return $existant
    }

    [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $reponse = Invoke-OcJson -Methode 'post' -Chemin '/api/session' -Corps @{ location = @{ directory = $resolu } }
    }
    catch {
        [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
        [System.Windows.Forms.MessageBox]::Show(
            ("Ajout impossible :`n`n" + $_.Exception.Message),
            'Gestion OpenCode', 'OK', 'Error') | Out-Null
        return $null
    }
    finally {
        [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
    }

    $idProjet = ''
    if ($reponse -and $reponse.data) { $idProjet = [string]$reponse.data.projectID }

    Update-GuiProjets -IdASelectionner $idProjet
    Set-GuiStatut ('Projet ajouté : ' + $resolu) 'ok'
    return $reponse
}

function Renommer-ProjetGui {
    param($Projet)
    if (-not $Projet) { return }

    $ancien = Get-ProjectNom $Projet
    $nouveau = Show-GuiSaisie -Titre 'Renommer le projet' -Invite 'Nouveau nom :' -Valeur $ancien
    if (-not $nouveau -or $nouveau -eq $ancien) { return }

    try {
        Invoke-OcJson -Methode 'patch' -Chemin ("/api/project/" + $Projet.id) -Corps @{ name = $nouveau } | Out-Null
        Update-GuiProjets -IdASelectionner $Projet.id
        Set-GuiStatut ('Projet renommé : ' + $nouveau) 'ok'
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            ("Renommage impossible :`n`n" + $_.Exception.Message),
            'Gestion OpenCode', 'OK', 'Error') | Out-Null
    }
}

function Ouvrir-ProjetGui {
    param($Projet)
    if (-not $Projet) { return }

    if (-not $Projet.canonical -or -not (Test-Path -LiteralPath $Projet.canonical -PathType Container)) {
        [System.Windows.Forms.MessageBox]::Show(
            ("Dossier introuvable :`n" + $Projet.canonical),
            'Gestion OpenCode', 'OK', 'Warning') | Out-Null
        return
    }

    try {
        Open-Projet ([pscustomobject]@{ canonical = $Projet.canonical; id = $Projet.id; name = $Projet.name })
        Set-GuiStatut ('OpenCode lancé dans : ' + $Projet.canonical) 'action'
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            ("Lancement impossible :`n`n" + $_.Exception.Message),
            'Gestion OpenCode', 'OK', 'Error') | Out-Null
    }
}

function Show-GuiDetail {
    param($Session)
    if (-not $Session) { return }

    $lignes = @()
    $lignes += (Get-TitreSession $Session)
    $lignes += ''
    $lignes += ('Identifiant   : ' + $Session.id)
    $lignes += ('Projet        : ' + $Session.projectID)
    if ($Session.location -and $Session.location.directory) { $lignes += ('Dossier       : ' + $Session.location.directory) }
    $lignes += ('Créée le      : ' + (Format-Date $Session.time.created))
    $lignes += ('Modifiée le   : ' + (Format-Date $Session.time.updated))
    if ($Session.agent) { $lignes += ('Agent         : ' + $Session.agent) }
    if ($Session.model) { $lignes += ('Modèle        : ' + $Session.model.providerID + '/' + $Session.model.id) }
    if ($Session.parentID) { $lignes += ('Session mère  : ' + $Session.parentID) }
    if ($Session.tokens) { $lignes += ('Jetons        : ' + $Session.tokens.input + ' entrée / ' + $Session.tokens.output + ' sortie') }
    if ($null -ne $Session.cost) { $lignes += ('Coût          : ' + $Session.cost) }
    if ($Session.outcome) { $lignes += ('Résultat      : ' + $Session.outcome) }

    [System.Windows.Forms.MessageBox]::Show(
        ($lignes -join "`n"),
        'Détail de la session', 'OK', 'Information') | Out-Null
}

function New-UiMenu {
    param([object[]]$Entrees)

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $menu.BackColor = $script:UiFond3
    $menu.ForeColor = $script:UiTexte
    $menu.Font = $script:UiPolice
    $menu.ShowImageMargin = $false

    foreach ($e in $Entrees) {
        if ($e.Texte -eq '-') {
            [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
            continue
        }
        $item = $menu.Items.Add($e.Texte)
        $item.ForeColor = $script:UiTexte
        if ($e.Action) { $item.Add_Click($e.Action) }
    }

    return $menu
}

function Add-GuiArbreControle {
    param($Controle, [int]$Niveau, $Lignes)

    $indent = ' ' * ($Niveau * 2)
    $texte = ''
    try { $texte = [string]$Controle.Text } catch { }
    $texte = ($texte -replace "`r?`n", ' | ')
    if ($texte.Length -gt 60) { $texte = $texte.Substring(0, 60) + '...' }
    try {
        $Lignes.Add(('{0}{1} [{2},{3} {4}x{5}] vis={6} ena={7} "{8}"' -f $indent, $Controle.GetType().Name, $Controle.Left, $Controle.Top, $Controle.Width, $Controle.Height, $Controle.Visible, $Controle.Enabled, $texte))
    }
    catch { }

    foreach ($enfant in $Controle.Controls) {
        Add-GuiArbreControle $enfant ($Niveau + 1) $Lignes
    }
}

function Invoke-GuiSelfTest {
    $journal = @()
    $dossier = Join-Path $env:TEMP ('oc-gui-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $dossier | Out-Null
    $journal += ('DOSSIER=' + $dossier)

    Add-ProjetGui -Chemin $dossier | Out-Null
    $projet = $script:GuiProjets |
        Where-Object { $_.canonical -and ($_.canonical.TrimEnd('\') -ieq $dossier.TrimEnd('\')) } |
        Select-Object -First 1

    if (-not $projet) {
        $journal += 'ECHEC : projet de test absent de la liste'
        return ($journal -join "`r`n")
    }

    Update-GuiSessions $projet
    $journal += ('SESSIONS=' + $script:GuiSessions.Count)
    $journal += ('GRILLE_LIGNES=' + $script:GuiGrilleSessions.Rows.Count)
    $journal += ('MODE_GRILLE_PROJETS=' + $script:GuiGrilleProjets.SelectionMode)
    $journal += ('MODE_GRILLE_SESSIONS=' + $script:GuiGrilleSessions.SelectionMode)

    if ($script:GuiSessions.Count -lt 1) {
        $journal += 'ECHEC : aucune session apres creation'
        return ($journal -join "`r`n")
    }

    $session = $script:GuiSessions[0]
    $journal += ('SESSION_ID=' + $session.id)

    Supprimer-GuiSessions -Cibles @($session) -SessionsCompletes $script:GuiSessionsBrutes -Contexte 'Test automatique'
    $restantes = @(Get-SessionsProjet -ProjectId $projet.id)
    $journal += ('RESTANTES=' + $restantes.Count)
    $journal += ('GRILLE_APRES=' + $script:GuiGrilleSessions.Rows.Count)

    # Scenario du bug : une session supprimee en dehors de l'application
    # (dans OpenCode) doit disparaitre de la grille sans clic sur Actualiser.
    $autoOk = $false
    try {
        $sessionExterne = Invoke-OcJson -Methode 'post' -Chemin '/api/session' -Corps @{ location = @{ directory = $dossier } }
        if ($sessionExterne -and $sessionExterne.data -and $sessionExterne.data.id) {
            Update-GuiProjets -IdASelectionner $projet.id
            $journal += ('GRILLE_AVANT_AUTO=' + $script:GuiGrilleSessions.Rows.Count)
            Invoke-OcApi -ArgListe @('api', 'delete', ('/api/session/' + $sessionExterne.data.id)) | Out-Null
            $script:GuiPret = $true
            $script:GuiSignature = 'signature-obsolete'
            Update-GuiAutoRefresh
            $journal += ('GRILLE_APRES_AUTO=' + $script:GuiGrilleSessions.Rows.Count)
            $autoOk = ($script:GuiGrilleSessions.Rows.Count -eq 0)
        }
        else {
            $journal += 'ECHEC : creation de session externe impossible'
        }
    }
    catch {
        $journal += ('ERREUR_AUTO=' + $_.Exception.Message)
    }

    # Verifie qu'une session archivee reste cachee dans la liste mais est bien
    # nettoyee lors de la suppression du projet (sinon la suppression echoue).
    $archiveOk = $false
    try {
        $sessionArchivee = Invoke-OcJson -Methode 'post' -Chemin '/api/session' -Corps @{ location = @{ directory = $dossier }; title = 'session archivee test' }
        if ($sessionArchivee -and $sessionArchivee.data -and $sessionArchivee.data.id) {
            Invoke-OcJson -Methode 'patch' -Chemin ('/api/session/' + $sessionArchivee.data.id) -Corps @{ archived = $true } | Out-Null
            Update-GuiProjets -IdASelectionner $projet.id
            $journal += ('GRILLE_ARCHIVEE=' + $script:GuiGrilleSessions.Rows.Count)
            $archiveOk = ($script:GuiGrilleSessions.Rows.Count -eq 0)
        }
        else {
            $journal += 'ECHEC : creation de session archivee impossible'
        }
    }
    catch {
        $journal += ('ERREUR_ARCHIVE=' + $_.Exception.Message)
    }

    # Suppression complete du projet (sessions restantes + entree dans la base).
    $script:GuiSelfTestErreurs = ''
    Supprimer-ProjetGui $projet
    if ($script:GuiSelfTestErreurs) { $journal += ('ERREUR_PROJET=' + $script:GuiSelfTestErreurs) }

    $projetReste = $true
    try {
        $projetReste = @(Get-Projects | Where-Object { $_.id -eq $projet.id }).Count -gt 0
    }
    catch { }
    $journal += ('PROJET_RESTANT=' + $projetReste)

    $lignesDb = -1
    try {
        $lignesDb = [OcSqlite]::Execute((Get-OcDbPath), 'select count(*) from project where id = ?', @($projet.id))
    }
    catch {
        $journal += ('ERREUR_DB=' + $_.Exception.Message)
    }
    $journal += ('PROJET_DB=' + $lignesDb)

    # Un projet supprime doit disparaitre de la liste tant qu'OpenCode ne le
    # recree pas (OpenCode le recree des qu'un client utilise le dossier).
    $absentIci = (@(Get-Projects | Where-Object { $_.id -eq $projet.id }).Count -eq 0)
    $journal += ('PROJET_ABSENT=' + $absentIci)

    $recreationVisible = $false
    try {
        $recree = Invoke-OcJson -Methode 'post' -Chemin '/api/session' -Corps @{ location = @{ directory = $dossier }; title = 'recreation test' }
        if ($recree -and $recree.data -and $recree.data.id) {
            $idRecree = [string]$recree.data.projectID
            $reapparuOpenCode = @(Get-Projects | Where-Object { $_.id -eq $idRecree }).Count -gt 0
            Update-GuiProjets
            $ligneReapparue = $false
            foreach ($r in $script:GuiGrilleProjets.Rows) {
                if ($r.Tag -and [string]$r.Tag.id -eq $idRecree) { $ligneReapparue = $true; break }
            }
            $journal += ('RECREE_OPENCODE=' + $reapparuOpenCode)
            $journal += ('RECREE_GRILLE=' + $ligneReapparue)
            # Sans masquage, un projet recree par OpenCode doit reapparaitre ici.
            $recreationVisible = ($reapparuOpenCode -and $ligneReapparue)
            Invoke-OcApi -ArgListe @('api', 'delete', ('/api/session/' + $recree.data.id)) | Out-Null
            try { Remove-ProjetBase -ProjectId $idRecree | Out-Null } catch { }
        }
        else {
            $journal += 'ECHEC : recreation du projet impossible'
        }
    }
    catch {
        $journal += ('ERREUR_RECREATION=' + $_.Exception.Message)
    }

    if ($restantes.Count -eq 0 -and $autoOk -and $archiveOk -and (-not $projetReste) -and $lignesDb -eq 0 -and $absentIci -and $recreationVisible -and
        ([string]$script:GuiGrilleProjets.SelectionMode -eq 'FullRowSelect') -and ([string]$script:GuiGrilleSessions.SelectionMode -eq 'FullRowSelect')) {
        $journal += 'RESULTAT=OK'
    }
    else {
        $journal += 'RESULTAT=ECHEC'
    }

    Remove-Item -LiteralPath $dossier -Recurse -Force -ErrorAction SilentlyContinue
    return ($journal -join "`r`n")
}

function Start-Gui {
    param([string]$CheminInitial = '')

    [System.Windows.Forms.Application]::EnableVisualStyles()
    Initialize-GuiStyle

    $script:GuiProjets         = @()
    $script:GuiSessions        = @()
    $script:GuiSessionsBrutes  = @()
    $script:GuiProjetCourant   = $null
    $script:GuiRemplissage     = $false
    $script:GuiCheminInitial   = $CheminInitial
    $script:GuiSessionsSupprimees = @()
    $script:GuiPret            = $false
    $script:GuiRafraichissement = $false
    $script:GuiSignature       = ''

    $form = New-Object System.Windows.Forms.Form
    $script:GuiForm = $form
    $form.Text = 'Gestion OpenCode'
    $form.StartPosition = 'CenterScreen'
    $form.ClientSize = New-Object System.Drawing.Size(1140, 730)
    $form.MinimumSize = New-Object System.Drawing.Size(960, 620)
    $form.BackColor = $script:UiFond
    $form.ForeColor = $script:UiTexte
    $form.Font = $script:UiPolice
    $form.KeyPreview = $true

    # --- Structure generale -------------------------------------------------

    $principal = New-Object System.Windows.Forms.TableLayoutPanel
    $principal.Dock = 'Fill'
    $principal.ColumnCount = 1
    $principal.RowCount = 3
    $principal.BackColor = $script:UiFond
    $principal.Margin = New-Object System.Windows.Forms.Padding(0)
    [void]$principal.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 134)))
    [void]$principal.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$principal.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 28)))
    $form.Controls.Add($principal)

    # --- Bandeau avec le logo ----------------------------------------------

    $bandeau = New-Object System.Windows.Forms.TableLayoutPanel
    $bandeau.Dock = 'Fill'
    $bandeau.ColumnCount = 2
    $bandeau.RowCount = 1
    $bandeau.BackColor = $script:UiFond2
    $bandeau.Margin = New-Object System.Windows.Forms.Padding(0)
    [void]$bandeau.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 400)))
    [void]$bandeau.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $principal.Controls.Add($bandeau, 0, 0)

    $logo = New-Object System.Windows.Forms.Label
    $logo.Text = $script:LogoAscii
    $logo.Dock = 'Fill'
    $logo.AutoSize = $false
    $logo.TextAlign = 'MiddleLeft'
    $logo.Font = $script:UiPoliceLogo
    $logo.ForeColor = $script:UiAccent
    $logo.Padding = New-Object System.Windows.Forms.Padding(16, 5, 0, 0)
    $logo.UseMnemonic = $false
    $bandeau.Controls.Add($logo, 0, 0)

    $blocTitre = New-Object System.Windows.Forms.Panel
    $blocTitre.Dock = 'Fill'
    $blocTitre.BackColor = $script:UiFond2
    $bandeau.Controls.Add($blocTitre, 1, 0)

    $titre = New-Object System.Windows.Forms.Label
    $titre.Text = 'Projets et sessions'
    $titre.Font = $script:UiPoliceTitre
    $titre.ForeColor = [System.Drawing.Color]::White
    $titre.AutoSize = $true
    $titre.Location = New-Object System.Drawing.Point(4, 30)
    $blocTitre.Controls.Add($titre)

    $sousTitre = New-Object System.Windows.Forms.Label
    $sousTitre.Text = "Sélectionnez un projet à gauche pour voir ses sessions.`nClic droit pour supprimer une session ou le projet, voir les détails, renommer ou ouvrir dans OpenCode."
    $sousTitre.ForeColor = $script:UiTexteDim
    $sousTitre.AutoSize = $true
    $sousTitre.Location = New-Object System.Drawing.Point(7, 74)
    $blocTitre.Controls.Add($sousTitre)

    # --- Grilles et boutons -------------------------------------------------

    $script:GuiGrilleProjets = New-UiGrille
    $script:GuiGrilleProjets.MultiSelect = $false
    $script:GuiGrilleProjets.SelectionMode = 'FullRowSelect'
    [void]$script:GuiGrilleProjets.Columns.Add((New-UiColonne -Titre 'PROJET' -Poids 100))
    [void]$script:GuiGrilleProjets.Columns.Add((New-UiColonne -Titre 'SESS.' -Largeur 58 -Alignement 'MiddleCenter'))
    [void]$script:GuiGrilleProjets.Columns.Add((New-UiColonne -Titre 'DERNIÈRE ACTIVITÉ' -Largeur 138))

    $boutonsProjets = New-Object System.Windows.Forms.FlowLayoutPanel
    $boutonsProjets.Dock = 'Fill'
    $boutonsProjets.BackColor = $script:UiFond
    $boutonsProjets.Padding = New-Object System.Windows.Forms.Padding(10, 10, 10, 8)
    $boutonsProjets.WrapContents = $true

    $btnAjouter = New-UiBouton -Texte '+  Ajouter un projet' -Largeur 168 -Accent
    $btnAjouter.Add_Click({ Invoke-GuiAction { Add-ProjetGui | Out-Null } })
    $boutonsProjets.Controls.Add($btnAjouter)

    $btnOuvrir = New-UiBouton -Texte 'Ouvrir' -Largeur 90
    $btnOuvrir.Add_Click({
        Invoke-GuiAction {
            $row = $script:GuiGrilleProjets.CurrentRow
            if ($row -and $row.Tag) { Ouvrir-ProjetGui $row.Tag }
        }
    })
    $boutonsProjets.Controls.Add($btnOuvrir)

    $btnRafraichir = New-UiBouton -Texte 'Actualiser' -Largeur 100
    $btnRafraichir.Add_Click({
        Invoke-GuiAction {
            $id = ''
            if ($script:GuiProjetCourant) { $id = [string]$script:GuiProjetCourant.id }
            Update-GuiProjets -IdASelectionner $id
            $sig = Get-GuiSignature
            if ($sig) { $script:GuiSignature = $sig }
        }
    })
    $boutonsProjets.Controls.Add($btnRafraichir)

    $script:GuiBtnSupprimerProjet = New-UiBouton -Texte 'Supprimer le projet…' -Largeur 190 -Danger
    $script:GuiBtnSupprimerProjet.Add_Click({
        Invoke-GuiAction {
            $row = $script:GuiGrilleProjets.CurrentRow
            if ($row -and $row.Tag) { Supprimer-ProjetGui $row.Tag }
        }
    })
    $boutonsProjets.Controls.Add($script:GuiBtnSupprimerProjet)

    $panneauProjets = New-Object System.Windows.Forms.TableLayoutPanel
    $panneauProjets.Dock = 'Fill'
    $panneauProjets.ColumnCount = 1
    $panneauProjets.RowCount = 3
    $panneauProjets.BackColor = $script:UiFond
    $panneauProjets.Margin = New-Object System.Windows.Forms.Padding(0)
    [void]$panneauProjets.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 34)))
    [void]$panneauProjets.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$panneauProjets.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 92)))

    $titreProjets = New-Object System.Windows.Forms.Label
    $titreProjets.Text = 'PROJETS'
    $titreProjets.Dock = 'Fill'
    $titreProjets.TextAlign = 'MiddleLeft'
    $titreProjets.Padding = New-Object System.Windows.Forms.Padding(12, 0, 0, 0)
    $titreProjets.Font = $script:UiPoliceGras
    $titreProjets.ForeColor = $script:UiAccent
    $script:GuiTitreProjets = $titreProjets

    $enteteProjets = New-Object System.Windows.Forms.Panel
    $enteteProjets.Dock = 'Fill'
    $enteteProjets.BackColor = $script:UiFond
    $enteteProjets.Controls.Add($titreProjets)

    $panneauProjets.Controls.Add($enteteProjets, 0, 0)
    $panneauProjets.Controls.Add($script:GuiGrilleProjets, 0, 1)
    $panneauProjets.Controls.Add($boutonsProjets, 0, 2)

    $script:GuiGrilleSessions = New-UiGrille
    $script:GuiGrilleSessions.MultiSelect = $true
    $script:GuiGrilleSessions.SelectionMode = 'FullRowSelect'
    [void]$script:GuiGrilleSessions.Columns.Add((New-UiColonne -Titre 'SESSION' -Poids 100))
    [void]$script:GuiGrilleSessions.Columns.Add((New-UiColonne -Titre 'SOUS-SESS.' -Largeur 90 -Alignement 'MiddleCenter'))
    [void]$script:GuiGrilleSessions.Columns.Add((New-UiColonne -Titre 'MODIFIÉE' -Largeur 138))

    $boutonsSessions = New-Object System.Windows.Forms.FlowLayoutPanel
    $boutonsSessions.Dock = 'Fill'
    $boutonsSessions.BackColor = $script:UiFond
    $boutonsSessions.Padding = New-Object System.Windows.Forms.Padding(10, 10, 10, 8)
    $boutonsSessions.WrapContents = $false

    $script:GuiBtnNouvelle = New-UiBouton -Texte '+  Nouvelle session' -Largeur 160 -Accent
    $script:GuiBtnNouvelle.Add_Click({
        Invoke-GuiAction {
            if (-not $script:GuiProjetCourant) { return }
            [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
            try {
                $dossier = $script:GuiProjetCourant.canonical
                Invoke-OcJson -Methode 'post' -Chemin '/api/session' -Corps @{ location = @{ directory = $dossier } } | Out-Null
            }
            finally { [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default }
            Update-GuiProjets -IdASelectionner $script:GuiProjetCourant.id
            Set-GuiStatut 'Nouvelle session créée.' 'ok'
        }
    })
    $boutonsSessions.Controls.Add($script:GuiBtnNouvelle)

    $script:GuiBtnDetail = New-UiBouton -Texte 'Détails' -Largeur 90
    $script:GuiBtnDetail.Add_Click({
        Invoke-GuiAction {
            $row = $script:GuiGrilleSessions.CurrentRow
            if ($row -and $row.Tag) { Show-GuiDetail $row.Tag }
        }
    })
    $boutonsSessions.Controls.Add($script:GuiBtnDetail)

    $script:GuiBtnSupprimer = New-UiBouton -Texte 'Supprimer…' -Largeur 105 -Danger
    $script:GuiBtnSupprimer.Add_Click({ Invoke-GuiAction { Supprimer-GuiSelection } })
    $boutonsSessions.Controls.Add($script:GuiBtnSupprimer)

    $script:GuiBtnToutSupprimer = New-UiBouton -Texte 'Tout supprimer' -Largeur 120 -Danger
    $script:GuiBtnToutSupprimer.Add_Click({
        Invoke-GuiAction { Supprimer-GuiSessionsProjet $script:GuiProjetCourant }
    })
    $boutonsSessions.Controls.Add($script:GuiBtnToutSupprimer)

    $panneauSessions = New-Object System.Windows.Forms.TableLayoutPanel
    $panneauSessions.Dock = 'Fill'
    $panneauSessions.ColumnCount = 1
    $panneauSessions.RowCount = 3
    $panneauSessions.BackColor = $script:UiFond
    $panneauSessions.Margin = New-Object System.Windows.Forms.Padding(0)
    [void]$panneauSessions.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 34)))
    [void]$panneauSessions.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$panneauSessions.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 52)))

    $script:GuiTitreSessions = New-Object System.Windows.Forms.Label
    $script:GuiTitreSessions.Text = 'SESSIONS'
    $script:GuiTitreSessions.Dock = 'Fill'
    $script:GuiTitreSessions.TextAlign = 'MiddleLeft'
    $script:GuiTitreSessions.Padding = New-Object System.Windows.Forms.Padding(12, 0, 0, 0)
    $script:GuiTitreSessions.Font = $script:UiPoliceGras
    $script:GuiTitreSessions.ForeColor = $script:UiAccent

    $panneauSessions.Controls.Add($script:GuiTitreSessions, 0, 0)
    $panneauSessions.Controls.Add($script:GuiGrilleSessions, 0, 1)
    $panneauSessions.Controls.Add($boutonsSessions, 0, 2)

    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock = 'Fill'
    $split.Orientation = 'Vertical'
    $split.SplitterWidth = 5
    $split.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 58)
    $split.Panel1.BackColor = $script:UiFond
    $split.Panel2.BackColor = $script:UiFond
    $script:GuiSplit = $split
    $split.Panel1.Controls.Add($panneauProjets)
    $split.Panel2.Controls.Add($panneauSessions)
    $principal.Controls.Add($split, 0, 1)

    $script:GuiStatut = New-Object System.Windows.Forms.Label
    $script:GuiStatut.Dock = 'Fill'
    $script:GuiStatut.TextAlign = 'MiddleLeft'
    $script:GuiStatut.BackColor = $script:UiFond3
    $script:GuiStatut.ForeColor = $script:UiTexteDim
    $script:GuiStatut.Text = '  Chargement...'
    $script:GuiStatut.Margin = New-Object System.Windows.Forms.Padding(0)
    $principal.Controls.Add($script:GuiStatut, 0, 2)

    # --- Menus contextuels --------------------------------------------------

    $menuProjet = New-UiMenu -Entrees @(
        @{ Texte = 'Voir les sessions'; Action = {
                $row = $script:GuiGrilleProjets.CurrentRow
                if ($row -and $row.Tag) { Update-GuiSessions $row.Tag }
            }
        },
        @{ Texte = 'Ouvrir dans OpenCode'; Action = {
                $row = $script:GuiGrilleProjets.CurrentRow
                if ($row -and $row.Tag) { Ouvrir-ProjetGui $row.Tag }
            }
        },
        @{ Texte = 'Renommer…'; Action = {
                $row = $script:GuiGrilleProjets.CurrentRow
                if ($row -and $row.Tag) { Renommer-ProjetGui $row.Tag }
            }
        },
        @{ Texte = '-' },
        @{ Texte = 'Supprimer toutes ses sessions'; Action = {
                $row = $script:GuiGrilleProjets.CurrentRow
                if ($row -and $row.Tag) { Supprimer-GuiSessionsProjet $row.Tag }
            }
        },
        @{ Texte = 'Supprimer le projet…'; Action = {
                $row = $script:GuiGrilleProjets.CurrentRow
                if ($row -and $row.Tag) { Supprimer-ProjetGui $row.Tag }
            }
        }
    )

    $menuSession = New-UiMenu -Entrees @(
        @{ Texte = 'Supprimer cette session'; Action = { Supprimer-GuiSelection } },
        @{ Texte = 'Détails'; Action = {
                $row = $script:GuiGrilleSessions.CurrentRow
                if ($row -and $row.Tag) { Show-GuiDetail $row.Tag }
            }
        },
        @{ Texte = '-' },
        @{ Texte = 'Ouvrir le dossier dans OpenCode'; Action = {
                $row = $script:GuiGrilleSessions.CurrentRow
                if ($row -and $row.Tag -and $row.Tag.location -and $row.Tag.location.directory) {
                    Ouvrir-ProjetGui ([pscustomobject]@{
                            canonical = $row.Tag.location.directory
                            id        = $row.Tag.projectID
                        })
                }
            }
        }
    )

    # --- Evenements ---------------------------------------------------------

    $script:GuiGrilleProjets.Add_SelectionChanged({
        if ($script:GuiRemplissage) { return }
        $row = $script:GuiGrilleProjets.CurrentRow
        $idNouveau = ''
        if ($row -and $row.Tag) { $idNouveau = [string]$row.Tag.id }
        $idActuel = ''
        if ($script:GuiProjetCourant) { $idActuel = [string]$script:GuiProjetCourant.id }
        if ($idNouveau -ne $idActuel) { Update-GuiSessions $row.Tag }
    })

    $script:GuiGrilleProjets.Add_CellMouseDown({
        param($sender, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
            if ($e.RowIndex -ge 0) {
                $sender.ClearSelection()
                $sender.Rows[$e.RowIndex].Selected = $true
                $sender.CurrentCell = $sender.Rows[$e.RowIndex].Cells[0]
            }
            $sender.Focus() | Out-Null
            $menuProjet.Show($sender, $e.Location)
        }
    })

    $script:GuiGrilleProjets.Add_CellDoubleClick({
        param($sender, $e)
        if ($e.RowIndex -ge 0 -and $sender.Rows[$e.RowIndex].Tag) {
            Ouvrir-ProjetGui $sender.Rows[$e.RowIndex].Tag
        }
    })

    $script:GuiGrilleSessions.Add_CellMouseDown({
        param($sender, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right -and $e.RowIndex -ge 0) {
            if (-not $sender.Rows[$e.RowIndex].Selected) {
                $sender.ClearSelection()
                $sender.Rows[$e.RowIndex].Selected = $true
                $sender.CurrentCell = $sender.Rows[$e.RowIndex].Cells[0]
            }
            $sender.Focus() | Out-Null
            $menuSession.Show($sender, $e.Location)
        }
    })

    $script:GuiGrilleSessions.Add_CellDoubleClick({
        param($sender, $e)
        if ($e.RowIndex -ge 0 -and $sender.Rows[$e.RowIndex].Tag) {
            Show-GuiDetail $sender.Rows[$e.RowIndex].Tag
        }
    })

    $script:GuiGrilleSessions.Add_KeyDown({
        param($sender, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Delete) {
            $e.Handled = $true
            Supprimer-GuiSelection
        }
    })

    $form.Add_KeyDown({
        param($sender, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::F5) {
            $id = ''
            if ($script:GuiProjetCourant) { $id = [string]$script:GuiProjetCourant.id }
            Update-GuiProjets -IdASelectionner $id
            $sig = Get-GuiSignature
            if ($sig) { $script:GuiSignature = $sig }
        }
    })

    # Quand on revient dans la fenetre (apres avoir supprime quelque chose
    # dans OpenCode par exemple), la liste se met a jour toute seule.
    $form.Add_Activated({
        try { Update-GuiAutoRefresh } catch { }
    })

    $form.Add_FormClosed({
        if ($script:GuiTimerRafraichissement) {
            try { $script:GuiTimerRafraichissement.Stop() } catch { }
            try { $script:GuiTimerRafraichissement.Dispose() } catch { }
            $script:GuiTimerRafraichissement = $null
        }
    })

    $form.Add_Shown({
        try {
            $script:GuiSplit.Panel1MinSize = 320
            $script:GuiSplit.Panel2MinSize = 400
            $largeur = $script:GuiSplit.Width
            $distance = [int]($largeur * 0.36)
            if ($distance -lt 340) { $distance = 340 }
            if ($distance -gt ($largeur - 400)) { $distance = $largeur - 400 }
            if ($distance -ge 320) { $script:GuiSplit.SplitterDistance = $distance }
        }
        catch { }

        Update-GuiProjets
        if ($script:GuiCheminInitial) {
            Add-ProjetGui -Chemin $script:GuiCheminInitial | Out-Null
            $script:GuiCheminInitial = ''
        }

        if ($env:OC_GESTION_LAYOUTDUMP) {
            $lignes = New-Object System.Collections.Generic.List[string]
            Add-GuiArbreControle $script:GuiForm 0 $lignes
            [System.IO.File]::WriteAllLines($env:OC_GESTION_LAYOUTDUMP, $lignes, (New-Object System.Text.UTF8Encoding($true)))
        }

        if ($env:OC_GESTION_SELFTEST_AUTO) {
            $journal = Invoke-GuiSelfTest
            $cheminJournal = Join-Path $env:TEMP 'oc_gui_selftest.log'
            if ($env:OC_GESTION_SELFTEST_LOG) { $cheminJournal = $env:OC_GESTION_SELFTEST_LOG }
            [System.IO.File]::WriteAllText($cheminJournal, $journal, (New-Object System.Text.UTF8Encoding($true)))
        }

        $signature = Get-GuiSignature
        if ($signature) { $script:GuiSignature = $signature }
        $script:GuiPret = $true
    })

    # --- Rafraichissement automatique ---------------------------------------

    if (-not $env:OC_GESTION_SELFTEST -and -not $env:OC_GESTION_SELFTEST_AUTO) {
        $script:GuiTimerRafraichissement = New-Object System.Windows.Forms.Timer
        $script:GuiTimerRafraichissement.Interval = 15000
        $script:GuiTimerRafraichissement.Add_Tick({
            if (-not $script:GuiForm -or -not $script:GuiForm.ContainsFocus) { return }
            try { Update-GuiAutoRefresh } catch { }
        })
        $script:GuiTimerRafraichissement.Start()
    }

    # --- Diagnostic (test automatise de l'interface) -------------------------

    if ($env:OC_GESTION_SELFTEST) {
        $minuteur = New-Object System.Windows.Forms.Timer
        $minuteur.Interval = 2500
        if ($env:OC_GESTION_SELFTEST_MS) {
            try { $minuteur.Interval = [int]$env:OC_GESTION_SELFTEST_MS } catch { }
        }
        $minuteur.Add_Tick({
            $minuteur.Stop()
            $script:GuiForm.Close()
        })
        $minuteur.Start()
    }

    [void]$form.ShowDialog()
    $form.Dispose()
}

# ---------------------------------------------------------------------------
#  Demarrage
# ---------------------------------------------------------------------------

if (-not (Initialize-Oc)) {
    if ($Gui) {
        [System.Windows.Forms.MessageBox]::Show(
            "OpenCode est introuvable sur cet ordinateur.`n`nInstallez OpenCode (application de bureau) puis relancez.",
            'Gestion OpenCode', 'OK', 'Error') | Out-Null
    }
    return
}

# Mode non interactif : -List  (affiche les projets puis quitte)
if ($List) {
    try {
        $projets = @(Get-Projects)
        Write-Host ''
        Write-Entete 'Projets OpenCode'
        if ($projets.Count -eq 0) {
            Write-Alerte 'Aucun projet enregistre.'
        }
        else {
            $i = 0
            foreach ($p in $projets) {
                $i++
                $nb = 0
                try { $nb = @(Get-Racines (Get-SessionsProjet -ProjectId $p.id)).Count } catch { $nb = -1 }
                Write-Host ("  {0,2}. {1}  [{2} session(s)]" -f $i, (Get-ProjectNom $p), $nb) -ForegroundColor White
                Write-Host ("      {0}" -f $p.canonical) -ForegroundColor DarkGray
            }
        }
        Write-Host ''
        return
    }
    catch {
        Write-Erreur ("Lecture des projets impossible : {0}" -f $_.Exception.Message)
        return
    }
}

# Mode non interactif : -Add "chemin"  (ajoute un projet puis quitte)
if ($Add) {
    $cible = $Add.Trim().Trim('"').Trim("'")
    if (-not $cible -or -not (Test-Path -LiteralPath $cible -PathType Container)) {
        Write-Erreur ("Dossier introuvable : {0}" -f $Add)
        exit 1
    }
    try {
        $resolu = (Resolve-Path -LiteralPath $cible).ProviderPath
        $existant = @(Get-Projects) |
            Where-Object { $_.canonical -and ($_.canonical.TrimEnd('\') -ieq $resolu.TrimEnd('\')) } |
            Select-Object -First 1

        if ($existant) {
            Write-Alerte ("Ce projet est deja enregistre : {0}" -f (Get-ProjectNom $existant))
            Write-Info ("Dossier : {0}" -f $resolu)
            return
        }

        $reponse = Invoke-OcJson -Methode 'post' -Chemin '/api/session' -Corps @{ location = @{ directory = $resolu } }
        Write-Succes ("Projet ajoute : {0}" -f $resolu)
        if ($reponse -and $reponse.data) {
            Write-Info ("Session creee : {0}" -f $reponse.data.id)
        }
        return
    }
    catch {
        Write-Erreur ("Echec de l'ajout : {0}" -f $_.Exception.Message)
        exit 1
    }
}

# Chemin fourni en argument (glisser-deposer sur le .bat)
$cheminInitial = ''
if ($Path -and $Path.Count -gt 0) {
    $candidat = (($Path -join ' ').Trim()).Trim('"')
    if ($candidat) {
        if ($Gui) {
            $cheminInitial = $candidat
        }
        else {
            Clear-Host
            Add-Projet -Chemin $candidat | Out-Null
            Write-Attente
        }
    }
}

if ($Gui) { Start-Gui -CheminInitial $cheminInitial }
elseif ($Menu) { Start-MenuClassique }
else { Start-Console }
