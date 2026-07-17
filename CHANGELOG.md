# Historique des versions

Ce fichier suit les évolutions notables du collecteur (`Collecte--ADCS.ps1`) et du visualiseur (`visualiseur-adcs.html`).

## 2026-07-17 — Collecteur v1.2 · Visualiseur v1.7

### Licence

- Passage de la GPLv3 à **MIT + Commons Clause v1.0** : usage, modification et redistribution libres, y compris en interne ; revente et prestations commerciales fondées sur l'outil interdites. Les copies antérieures obtenues sous GPLv3 restent régies par la GPLv3.

### Collecteur

- Export du code numérique du motif de révocation (`raisonCode`) dans le JSON, en complément du libellé. Ajout rétrocompatible : les anciens exports restent lisibles par le visualiseur.

### Visualiseur

- **Tri par urgence opérationnelle** par défaut : expirations imminentes en tête, certificats expirés et révoqués en fin de liste. La colonne « État » trie selon cette clé (état puis date).
- **Sélection des certificats expirés** pour la révocation individuelle et en masse ; seuls les certificats déjà révoqués restent non sélectionnables. Une note dans la fenêtre de révocation rappelle la portée (enregistrement en base ; visibilité en CRL soumise à `CRLF_PUBLISH_EXPIRED_CERT_CRLS`).
- **Levée de suspension** : sur un certificat révoqué au motif 6 (`certificateHold`), le panneau de détail pré-génère `certutil -revoke <série> unrevoke` et le rappel de republication de CRL.
- **Panneau d'action sur les échecs** : clic sur une ligne de l'onglet Échecs pour afficher le message complet et pré-générer les commandes d'investigation (`certutil -view -restrict "RequestID=N"`) et de relance (`-resubmit`).
- **Bordereau de campagne** : la fenêtre de révocation en masse peut copier un récapitulatif horodaté (CA, motif, lot, liste complète, champs opérateur et justification à compléter) destiné à un ticket ou à l'archivage.
- Recherche, tri et filtres sur les onglets « En attente » et « Échecs », dont un filtre par message d'échec trié par fréquence.
- Signal explicite lorsque « tout sélectionner » ne coche aucune ligne visible à l'écran ; cases non sélectionnables visuellement atténuées.

## Versions antérieures (publication initiale)

- Collecteur v1.1.1 : collecte en lecture seule via `ICertView`, auto-détection de la CA, lecture ASN.1 des CRL, sérialisation adaptée à PowerShell 5.1 et 7+, génération du visualiseur autoporteur.
- Visualiseur v1.4 : tableau de bord, frise des expirations, tables paginées et filtrables, détection de doublons, préparation des révocations unitaires et en masse, tenue en charge validée à 80 000 certificats et 75 000 échecs.
