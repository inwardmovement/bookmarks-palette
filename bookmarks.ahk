#Requires AutoHotkey v2.0
#SingleInstance Force
#NoTrayIcon

; ===========================================================================================
; Script de recherche de bookmarks Chrome
; Utilise _JXON.ahk pour parser le fichier JSON des bookmarks
; ===========================================================================================

; Inclure la librairie JSON
#Include _JXON.ahk

; Variables globales
global g_bookmarks := Map()
global g_searchResults := []
global g_gui := ""
global g_searchEdit := ""
global g_resultsList := ""
global g_guiVisible := false
global g_searchTimer := ""

; ===========================================================================================
; CONFIGURATION
; ===========================================================================================
global g_chromeBookmarksPaths := [
    EnvGet("LOCALAPPDATA") . "\Google\Chrome\User Data\Default\Bookmarks",
    EnvGet("LOCALAPPDATA") . "\Google\Chrome\User Data\Profile 6\Bookmarks"
]
global g_hotkey := "^Space"  ; Ctrl + Espace
global g_searchInFolderName := false
global g_showEQXPrefix := false

; ===========================================================================================
; FONCTIONS PRINCIPALES
; ===========================================================================================

; Fonction pour détecter si une application est en plein écran
isFullScreen() {
    try {
        WinGetPos(, , &w, &h, "A")
        return (w = A_ScreenWidth && h = A_ScreenHeight)
    } catch {
        return false
    }
}

; Initialisation du script
Init() {
    ; Enregistrer le hotkey avec condition de plein écran
    Hotkey(g_hotkey, OpenBookmarkPaletteWithFullscreenCheck)
}

; Fonction wrapper pour vérifier le plein écran avant d'ouvrir la palette
OpenBookmarkPaletteWithFullscreenCheck(*) {
    if !isFullScreen() {
        OpenBookmarkPalette()
    }
}

; Charger les bookmarks depuis Chrome (tous les profils)
LoadBookmarks() {
    global g_bookmarks, g_chromeBookmarksPaths
    g_bookmarks := Map()
    loadedCount := 0

    for bookmarksPath in g_chromeBookmarksPaths {
        try {
            if !FileExist(bookmarksPath) {
                ; Profil non trouvé, continuer avec les autres
                continue
            }

            ; Lire le fichier JSON avec encodage UTF-8
            fileContent := FileRead(bookmarksPath, "UTF-8")

            ; Parser le JSON
            bookmarksData := Jxon_Load(&fileContent)

            ; Extraire les bookmarks de ce profil
            profileBookmarks := ExtractBookmarks(bookmarksData)

            ; Fusionner avec les bookmarks existants
            for name, bookmarkData in profileBookmarks {
                ; Déterminer le préfixe selon le profil et le dossier
                if InStr(bookmarksPath, "Profile 6") {
                    ; Profile 6 : préfixe GIR toujours affiché (pas de dossier EQX dans ce profil)
                    displayName := "(GIR) " . name
                } else {
                    ; Profil par défaut : préfixe EQX si dans dossier EQX et si configuré, sinon pas de préfixe
                    if bookmarkData.isEQX {
                        if g_showEQXPrefix {
                            displayName := "(EQX) " . name
                        } else {
                            displayName := name
                        }
                    } else {
                        displayName := name
                    }
                }
                ; Stocker un objet avec le nom original, le nom affiché et l'URL
                isGIRProfile := InStr(bookmarksPath, "Profile 6")
                g_bookmarks[displayName] := { originalName: name, displayName: displayName, url: bookmarkData.url, path: bookmarkData
                    .path, isEQX: bookmarkData.isEQX, isGIRProfile: isGIRProfile
                }
            }

            loadedCount++
        } catch Error as e {
            ; Erreur sur ce profil, continuer avec les autres
            continue
        }
    }

    if loadedCount = 0 {
        MsgBox("Aucun profil Chrome trouvé avec des bookmarks", "Erreur", "Icon!")
        return false
    }

    return true
}

; Extraire récursivement tous les bookmarks
ExtractBookmarks(data, bookmarks := Map(), currentPath := "") {
    if !IsObject(data)
        return bookmarks

    ; Si c'est la racine, chercher dans "roots"
    if data.Has("roots") {
        ; Explorer chaque section de roots (bookmark_bar, other, synced)
        for key, value in data["roots"] {
            ExtractBookmarks(value, bookmarks, "")
        }
        return bookmarks
    }

    ; Construire le chemin actuel
    if data.Has("name") {
        if currentPath = "" {
            currentPath := data["name"]
        } else {
            currentPath := currentPath . " > " . data["name"]
        }
    }

    ; Parcourir les enfants
    if data.Has("children") {
        for child in data["children"] {
            if child.Has("type") {
                if child["type"] = "url" {
                    ; C'est un bookmark
                    if child.Has("name") && child.Has("url") {
                        ; Vérifier si le bookmark est dans un dossier EQX
                        if InStr(currentPath, "EQX") {
                            bookmarks[child["name"]] := { url: child["url"], path: currentPath, isEQX: true
                            }
                        } else {
                            bookmarks[child["name"]] := { url: child["url"], path: currentPath, isEQX: false
                            }
                        }
                    }
                }
                else if child["type"] = "folder" {
                    ; C'est un dossier, explorer récursivement
                    ExtractBookmarks(child, bookmarks, currentPath)
                }
            }
        }
    }

    return bookmarks
}

; Créer l'interface graphique
CreateGUI() {
    global g_gui, g_searchEdit, g_resultsList

    g_gui := Gui("+Resize -MaximizeBox -Caption +AlwaysOnTop +ToolWindow", "Favoris")
    g_gui.SetFont("s14", "Segoe UI")

    ; Couleurs
    bgColor := "0x1E1E1E"
    textColor := "0xC0C0C0"

    ; Fond de la fenêtre
    g_gui.BackColor := bgColor

    ; Zone de recherche avec bordure subtile
    g_searchEdit := g_gui.AddEdit("x0 y0 w400 h30 vSearchText c" . "White" . " Background" . bgColor . " +Border", ""
    )
    g_searchEdit.OnEvent("Change", SearchBookmarks)

    ; Liste des résultats avec thème sombre pour la barre de défilement
    g_resultsList := g_gui.AddListBox("x0 y30 w400 h300 vResultsList c" . textColor . " Background" . bgColor .
        " Hidden", [])
    g_resultsList.OnEvent("DoubleClick", OpenSelectedBookmark)

    ; Appliquer le thème sombre à la fenêtre et aux contrôles
    try {
        ; Appliquer le thème sombre à la fenêtre principale
        DllCall("uxtheme.dll\SetWindowTheme", "Ptr", g_gui.Hwnd, "WStr", "DarkMode_Explorer", "Ptr", 0)
        ; Appliquer le thème sombre aux contrôles pour la barre de défilement
        DllCall("uxtheme.dll\SetWindowTheme", "Ptr", g_resultsList.Hwnd, "WStr", "DarkMode_Explorer", "Ptr", 0)
        DllCall("uxtheme.dll\SetWindowTheme", "Ptr", g_searchEdit.Hwnd, "WStr", "DarkMode_Explorer", "Ptr", 0)
        ; Forcer le thème sombre de Windows 10/11
        DllCall("dwmapi.dll\DwmSetWindowAttribute", "Ptr", g_gui.Hwnd, "UInt", 20, "UInt*", 1, "UInt", 4)
    }

    ; Raccourcis clavier
    g_gui.OnEvent("Close", (*) => g_gui.Hide())

    ; Focus sur le champ de recherche
    g_searchEdit.Focus()
}

; Ouvrir la command palette
OpenBookmarkPalette(*) {
    global g_gui, g_guiVisible, g_searchEdit, g_resultsList
    ; Si la fenêtre est déjà ouverte, la fermer (toggle)
    if g_gui != "" && g_guiVisible {
        g_gui.Hide()
        g_guiVisible := false
        return
    }

    ; Créer le GUI s'il n'existe pas
    CreateGUI()

    ; Actualiser les bookmarks à chaque ouverture
    LoadBookmarks()

    ; Afficher le GUI (centré, taille fixe sans marges)
    g_gui.Show("w400 h330 Center")
    g_guiVisible := true
    g_searchEdit.Focus()
    g_searchEdit.Text := ""
    g_resultsList.Text := ""
}

; Rechercher dans les bookmarks
SearchBookmarks(*) {
    global g_bookmarks, g_searchResults, g_resultsList, g_searchTimer

    ; Annuler le timer précédent s'il existe
    if g_searchTimer != "" {
        SetTimer(g_searchTimer, 0)
        g_searchTimer := ""
    }

    ; Masquer immédiatement la liste dès qu'on tape quelque chose
    g_resultsList.Visible := false

    ; Programmer une nouvelle recherche avec un délai de 150ms
    g_searchTimer := DelayedSearch
    SetTimer(g_searchTimer, 100)
}

; Recherche différée pour éviter les recherches trop fréquentes
DelayedSearch() {
    global g_bookmarks, g_searchResults, g_resultsList, g_searchEdit, g_searchTimer

    ; Annuler le timer
    SetTimer(g_searchTimer, 0)
    g_searchTimer := ""

    searchText := g_searchEdit.Text
    g_searchResults := []

    if searchText = "" {
        g_resultsList.Delete()
        return
    }

    ; Recherche insensible à la casse et aux accents
    searchText := StrLower(NormalizeAccents(searchText))

    ; Filtrer les bookmarks avec recherche simple
    for displayName, bookmarkData in g_bookmarks {
        ; Utiliser le nom original pour la recherche
        originalName := bookmarkData.originalName
        originalNameLower := StrLower(NormalizeAccents(originalName))
        pathLower := StrLower(NormalizeAccents(bookmarkData.path))

        ; Recherche par mots : correspondance en début de mot uniquement
        searchInName := false
        if searchText != "" {
            ; Vérifier si le terme commence le nom complet
            if InStr(originalNameLower, searchText) = 1 {
                searchInName := true
            } else {
                ; Vérifier si le terme commence un mot (après un espace)
                searchPattern := " " . searchText
                if InStr(originalNameLower, searchPattern) > 0 {
                    searchInName := true
                }
            }
        }

        ; Recherche dans le chemin (optionnel)
        searchInPath := false
        if g_searchInFolderName && searchText != "" {
            if InStr(pathLower, searchText) = 1 {
                searchInPath := true
            } else {
                searchPattern := " " . searchText
                if InStr(pathLower, searchPattern) > 0 {
                    searchInPath := true
                }
            }
        }

        if searchInName || searchInPath {
            ; Score simple basé sur la position de la correspondance
            score := 0

            ; Si correspondance dans le nom
            if searchInName {
                ; Score élevé si le nom commence par le terme de recherche
                if InStr(originalNameLower, searchText) = 1
                    score := 1000
                ; Score moyen pour les correspondances en début de mot
                else
                    score := 800
            }

            ; Si correspondance uniquement dans le chemin
            if searchInPath && !searchInName {
                score := 300
            }

            ; Priorité : profil par défaut > EQX > GIR
            if bookmarkData.isEQX {
                priority := 1
            } else if bookmarkData.isGIRProfile {
                priority := 0
            } else {
                priority := 2
            }

            g_searchResults.Push({ name: displayName, url: bookmarkData.url, score: score, priority: priority
            })
        }
    }

    ; Trier par score de pertinence (décroissant) puis par nom
    if g_searchResults.Length > 1 {
        ; Pré-calculer les noms normalisés pour optimiser le tri
        for i, result in g_searchResults {
            result.normalizedName := StrLower(NormalizeAccents(result.name))
        }

        ; Tri à bulles simple et fiable
        loop g_searchResults.Length - 1 {
            i := A_Index
            loop g_searchResults.Length - i {
                j := A_Index
                ; Trier d'abord par score (décroissant), puis par priorité (décroissant), puis par nom (croissant)
                shouldSwap := false

                ; Comparer par score (décroissant)
                if g_searchResults[j].score < g_searchResults[j + 1].score {
                    shouldSwap := true
                } else if g_searchResults[j].score = g_searchResults[j + 1].score {
                    ; Si scores égaux, comparer par priorité (décroissant)
                    if g_searchResults[j].priority < g_searchResults[j + 1].priority {
                        shouldSwap := true
                    } else if g_searchResults[j].priority = g_searchResults[j + 1].priority {
                        ; Si même priorité, comparer par nom (croissant)
                        if StrCompare(g_searchResults[j].normalizedName, g_searchResults[j + 1].normalizedName) > 0 {
                            shouldSwap := true
                        }
                    }
                }

                if shouldSwap {
                    temp := g_searchResults[j]
                    g_searchResults[j] := g_searchResults[j + 1]
                    g_searchResults[j + 1] := temp
                }
            }
        }

    }

    ; Mettre à jour la liste
    displayResults := []
    for result in g_searchResults {
        displayResults.Push(result.name)
    }

    ; Vider la liste et ajouter les éléments un par un
    g_resultsList.Delete()
    for item in displayResults {
        g_resultsList.Add([item
        ])
    }

    ; Afficher la liste s'il y a des résultats
    if g_searchResults.Length > 0 && searchText != "" {
        g_resultsList.Visible := true
        g_resultsList.Choose(1)  ; Sélectionner le premier résultat
    } else {
        g_resultsList.Visible := false  ; Masquer la liste si aucun résultat ou texte vide
        g_resultsList.Delete()  ; Vider complètement la liste
    }
}

; Ouvrir le bookmark sélectionné
OpenSelectedBookmark(*) {
    global g_guiVisible
    selectedIndex := g_resultsList.Value
    if selectedIndex > 0 && selectedIndex <= g_searchResults.Length {
        bookmark := g_searchResults[selectedIndex]
        OpenInChrome(bookmark.url)
        g_gui.Hide()
        g_guiVisible := false
    }
}

; Ouvrir un URL dans Chrome
OpenInChrome(url) {
    try {
        ; Essayer d'ouvrir dans un nouvel onglet Chrome
        Run('chrome.exe --new-tab "' . url . '"')
    }
    catch {
        ; Fallback : utiliser le navigateur par défaut
        Run('"' . url . '"')
    }
}

; Actualiser les bookmarks
RefreshBookmarks(*) {
    if LoadBookmarks() {
        ; Relancer la recherche si il y a du texte
        if g_searchEdit.Text != "" {
            SearchBookmarks()
        }
        MsgBox("Bookmarks actualisés avec succès !", "Information", "Iconi")
    }
}

; ===========================================================================================
; GESTION DES RACCOURCIS CLAVIER
; ===========================================================================================

; Raccourcis dans le GUI
#HotIf WinActive("Favoris")
{
    ; Entrée pour ouvrir le bookmark sélectionné
    Enter:: OpenSelectedBookmark()

    ; Échap pour fermer
    Escape:: {
        global g_guiVisible
        g_gui.Hide()
        g_guiVisible := false
    }

    ; Flèches pour naviguer avec défilement infini
    Up:: {
        if g_searchResults.Length = 0
            return  ; Pas de résultats, ne rien faire
        if g_resultsList.Value > 1
            g_resultsList.Choose(g_resultsList.Value - 1)
        else
            g_resultsList.Choose(g_searchResults.Length)  ; Aller au dernier élément
    }
    Down:: {
        if g_searchResults.Length = 0
            return  ; Pas de résultats, ne rien faire
        if g_resultsList.Value < g_searchResults.Length
            g_resultsList.Choose(g_resultsList.Value + 1)
        else
            g_resultsList.Choose(1)  ; Revenir au premier élément
    }

    ; Tab pour naviguer vers le bas avec défilement infini
    Tab:: {
        if g_searchResults.Length = 0
            return  ; Pas de résultats, ne rien faire
        if g_resultsList.Value < g_searchResults.Length
            g_resultsList.Choose(g_resultsList.Value + 1)
        else
            g_resultsList.Choose(1)  ; Revenir au premier élément
    }

    ; Maj+Tab pour naviguer vers le haut avec défilement infini
    +Tab:: {
        if g_searchResults.Length = 0
            return  ; Pas de résultats, ne rien faire
        if g_resultsList.Value > 1
            g_resultsList.Choose(g_resultsList.Value - 1)
        else
            g_resultsList.Choose(g_searchResults.Length)  ; Aller au dernier élément
    }

    ; Ctrl+Backspace : comportement normal
    ^Backspace:: {
        ; Simuler Ctrl+Backspace normal
        Send("^+{Left}{Backspace}")
    }

}
#HotIf

; ===========================================================================================
; DÉMARRAGE DU SCRIPT
; ===========================================================================================

; Initialiser le script
Init()

; Message de démarrage supprimé

; ===========================================================================================
; FONCTIONS DE RECHERCHE
; ===========================================================================================

; Normaliser les accents pour la recherche insensible aux accents
NormalizeAccents(text) {
    ; Table de correspondance des caractères accentués vers leur équivalent sans accent
    accentMap := Map(
        "à", "a", "á", "a", "â", "a", "ã", "a", "ä", "a", "å", "a",
        "è", "e", "é", "e", "ê", "e", "ë", "e",
        "ì", "i", "í", "i", "î", "i", "ï", "i",
        "ò", "o", "ó", "o", "ô", "o", "õ", "o", "ö", "o",
        "ù", "u", "ú", "u", "û", "u", "ü", "u",
        "ý", "y", "ÿ", "y",
        "ñ", "n", "ç", "c",
        "À", "A", "Á", "A", "Â", "A", "Ã", "A", "Ä", "A", "Å", "A",
        "È", "E", "É", "E", "Ê", "E", "Ë", "E",
        "Ì", "I", "Í", "I", "Î", "I", "Ï", "I",
        "Ò", "O", "Ó", "O", "Ô", "O", "Õ", "O", "Ö", "O",
        "Ù", "U", "Ú", "U", "Û", "U", "Ü", "U",
        "Ý", "Y", "Ÿ", "Y",
        "Ñ", "N", "Ç", "C"
    )

    result := ""
    loop StrLen(text) {
        char := SubStr(text, A_Index, 1)
        if accentMap.Has(char) {
            result .= accentMap[char]
        } else {
            result .= char
        }
    }

    return result
}

; Garder le script actif
Persistent
