# 🎮 GameBarPlus (CoreBar)

**GameBarPlus** est une alternative ultra-légère à la Game Bar Windows classique, entièrement scriptée en PowerShell. Conçue pour les gamers, elle permet d'optimiser Windows, de gérer ses jeux et de lancer un stream en direct sans faire ramer ton PC.

---

## ⚡ Prérequis & Lancement rapide

Pour utiliser GameBarPlus, tu as juste besoin d'ouvrir **PowerShell en administrateur** :
1. Appuie sur la touche **Windows**, tape `PowerShell`.
2. Fais un clic droit dessus et choisis **« Exécuter en tant qu'administrateur »**.

---

## 🚀 Étape 1 : Autoriser l'exécution des scripts

Par défaut, Windows bloque l'exécution des scripts PowerShell non signés. Active l'autorisation temporaire en collant cette commande :

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
📥 Étape 2 : Lancer GameBarPlus
Option A — Téléchargement et lancement direct (Recommandé)
Télécharge et exécute directement le script principal sans garder de fichiers inutiles :

PowerShell
./GameBarPlus.ps1
Option B — Installation en une ligne (Via GitHub)
Si tu n'as pas encore téléchargé le fichier localement, colle cette commande pour tout récupérer et lancer automatiquement :

PowerShell
Set-ExecutionPolicy Bypass -Scope Process -Force; iex (iwr -useb https://raw.githubusercontent.com/TON-PSEUDO-GITHUB/GameBarPlus/main/GameBarPlus.ps1)
(Pense à remplacer TON-PSEUDO-GITHUB par ton pseudo GitHub).

✨ Fonctionnalités & Raccourcis
Mode Gaming Un Clic : Ferme les processus secondaires (navigateurs, services inutiles) et bascule Windows en performances maximales.

Nettoyage de Cache : Supprime les fichiers temporaires et les caches de shaders (Steam, Epic, NVIDIA, AMD) pour réduire les stutters en jeu.

Mode Live (Ctrl + Alt + L) : Lance ou arrête un direct vers YouTube/Twitch encodé directement sur ta carte graphique (NVENC/AMF) pour consommer 0 % de CPU.
