# Renommage Audio (Swift, macOS)

Application macOS native : on glisse des fichiers MP3/WAV ou des dossiers sur l'icône, l'app analyse et propose les renommages et les tags, puis on valide ou on annule.

## Obtenir l'app

Le fichier `Renommage-Audio-macOS.zip` est produit automatiquement par GitHub Actions (onglet **Actions** du dépôt, puis le dernier build réussi, section **Artifacts**).

Première ouverture : clic droit sur l'app → Ouvrir → Ouvrir (l'app n'est pas signée par Apple).

## Fonctionnement

1. Analyse sans modification : parcours récursif, noms finaux et tags calculés.
2. Fenêtre de validation : compteurs, tableau AVANT / APRÈS. Seul « VALIDER LES MODIFICATIONS » applique. « ANNULER » ou fermer la fenêtre ne modifie rien.
3. Bilan réel du traitement.

Les règles de nommage, les attributs protégés (« Intro - Clean », « Extended Mix »…), les inversions, les conflits et les niveaux de confiance suivent le cahier des charges.

## Structure

```
Package.swift
Sources/AudioRenamerCore/   moteur : analyse des noms, tags ID3/WAV, plan, application, textes
Sources/RenommageAudio/     interface AppKit
Tests/                      tests du moteur (XCTest)
Resources/Info.plist        types de fichiers acceptés (MP3, WAV, dossiers)
scripts/make_app.sh         construit le .app et le zip
.github/workflows/          build automatique sur macOS
```

## Limites connues

- Le code n'a pas pu être compilé ni testé sur macOS au moment de l'écriture : le premier build GitHub peut révéler des erreurs de compilation à corriger.
- Tags WAV : seul le chunk `id3 ` est lu et écrit. Les tags RIFF `LIST INFO` ne sont pas lus.
- Pas de détection de doublons audio (V1).
