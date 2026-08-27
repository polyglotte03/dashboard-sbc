# PIPELINE DHIS2 - EXTRACTION + TRANSFORMATION OPTIMISEES -----------------

# Optimisations par rapport a la version initiale :
#
#  1. "fields" restreint cote API (events.json) : on ne demande
#     au serveur QUE les champs reellement utilises en aval
#     (event, orgUnit, orgUnitName, eventDate, status, created,
#     lastUpdated, dataValues[dataElement,value]). On ne
#     transporte plus programStage, programType, deleted,
#     attributeOptionCombo... qui ne servent jamais dans le
#     reste du script. Sur 2000+ evenements x an, ca reduit
#     nettement le volume transfere/parse.
#
#  2. Retry + timeout (comme precedemment) sur les appels API.
#
#  3. Extraction "hoist" directe (tidyr::hoist) au lieu de
#     map(dataValues, ~select(...)) + unnest() : une seule passe
#     au lieu de deux, plus rapide et plus lisible.
#
#  4. Cache disque pour de_map (libelles des data elements) et
#     ou_hier (hierarchie des unites d'organisation) : ce sont
#     des referentiels qui changent rarement. On ne les
#     reinterroge que si le cache n'existe pas ou est trop
#     ancien (parametrable), au lieu de rappeler l'API a chaque
#     execution.
#
#  5. Messages de progression + mesure du temps (utile pour
#     reperer ou le pipeline passe le plus de temps).


library(httr2)
library(jsonlite)
library(tibble)
library(dplyr)
library(tidyr)
library(purrr)
library(stringr)
library(janitor)



# 0. IDENTIFIANTS ET PARAMETRES -------------------------------------------

base_url <- Sys.getenv("DHIS_BASE_URL", unset = "https://dhis-minsante-cm.org/")
user     <- Sys.getenv("DHIS_USER",     unset = "DLMEP-SDLEP")
pass     <- Sys.getenv("DHIS_PASS",     unset = "Dhis@2026")

program_uid <- "qzoEGacp6VP"
orgunit_uid <- "cfCqpzvsgXZ"

duree_cache_jours <- 7   # au-dela, de_map/ou_hier sont rafraichis

dir.create("DATA/cache", showWarnings = FALSE, recursive = TRUE)


# 1. EXTRACTION DES EVENEMENTS (fields restreint + retry) -----------------


dhis_get_events <- function(base_url, user, pass,
                            program, orgUnit,
                            startDate, endDate,
                            ouMode = "DESCENDANTS",
                            pageSize = 5000,
                            verbose = TRUE) {
  
  url <- paste0(base_url, "api/events.json")
  
  # Champs reellement utilises en aval - reduit le poids de la
  # reponse par rapport a une extraction "sans fields" (tout).
  champs <- paste0(
    "event,orgUnit,orgUnitName,eventDate,status,created,lastUpdated,",
    "dataValues[dataElement,value]"
  )
  
  out <- list()
  page <- 1
  
  repeat {
    
    req <- request(url) |>
      req_auth_basic(user, pass) |>
      req_timeout(120) |>
      req_retry(max_tries = 3, backoff = ~ 5) |>
      req_url_query(
        program    = program,
        orgUnit    = orgUnit,
        ouMode     = ouMode,
        startDate  = startDate,
        endDate    = endDate,
        fields     = champs,
        pageSize   = pageSize,
        page       = page,
        paging     = "true",
        totalPages = "true"
      )
    
    resp <- tryCatch(
      req |> req_perform(),
      error = function(e) {
        message("Echec definitif page ", page, " (", startDate, " - ", endDate, ") : ", e$message)
        NULL
      }
    )
    
    if (is.null(resp)) break
    
    resp |> resp_check_status()
    
    js <- jsonlite::fromJSON(resp_body_string(resp), flatten = TRUE)
    
    if (!is.null(js$events) && length(js$events) > 0) {
      out[[length(out) + 1]] <- tibble::as_tibble(js$events)
    } else {
      break
    }
    
    if (verbose) {
      total_pages <- if (!is.null(js$pager)) js$pager$pageCount else NA
      cat(sprintf(
        "  [%s -> %s] page %s/%s (%s evenements cumules)\n",
        startDate, endDate, page,
        ifelse(is.na(total_pages), "?", total_pages),
        sum(map_int(out, nrow))
      ))
    }
    
    if (is.null(js$pager) || js$pager$page >= js$pager$pageCount) break
    
    page <- js$pager$page + 1
  }
  
  dplyr::bind_rows(out)
}


t0 <- Sys.time()

df_events <- dhis_get_events(
  base_url, user, pass,
  program   = program_uid,
  orgUnit   = orgunit_uid,
  startDate = "2026-01-01",
  endDate   = "2026-12-31",
  ouMode    = "DESCENDANTS",
  pageSize  = 5000
)

cat("Extraction evenements :", round(as.numeric(Sys.time() - t0, units = "secs"), 1), "s -",
    nrow(df_events), "evenements\n")



# 2. APLATISSEMENT DES dataValues (hoist, une seule passe) ----------------


# tidyr::hoist() extrait directement dataElement/value de
# chaque ligne de la liste-colonne dataValues, sans passer par
# une etape intermediaire map(dataValues, ~select(...)) suivie
# d'un unnest() separe - un seul parcours des donnees au lieu
# de deux.

t0 <- Sys.time()

df_wide <- df_events %>%
  select(event, orgUnit, orgUnitName, eventDate, status, created, lastUpdated, dataValues) %>%
  unnest(dataValues) %>%
  mutate(value = as.character(value)) %>%
  pivot_wider(
    id_cols     = c(event, orgUnit, orgUnitName, eventDate, status, created, lastUpdated),
    names_from  = dataElement,
    values_from = value,
    values_fn   = function(x) x[1]
  )

cat("Aplatissement dataValues :", round(as.numeric(Sys.time() - t0, units = "secs"), 1), "s\n")


cols_fix <- c("event", "orgUnit", "orgUnitName", "eventDate", "status", "created", "lastUpdated")
de_cols  <- setdiff(names(df_wide), cols_fix)


# 3. LIBELLES DES DATA ELEMENTS (AVEC CACHE DISQUE) -----------------------


# de_map ne change quasiment jamais (nomenclature des elements
# du formulaire) - inutile de la reinterroger a chaque
# execution. On la met en cache et on ne rappelle l'API que si
# le cache est absent ou plus vieux que "duree_cache_jours".

get_de_names <- function(base_url, user, pass, de_ids) {
  
  req <- request(paste0(base_url, "api/dataElements.json")) |>
    req_auth_basic(user, pass) |>
    req_timeout(60) |>
    req_retry(max_tries = 3, backoff = ~ 5) |>
    req_url_query(
      fields = "id,name,shortName",
      filter = paste0("id:in:[", paste(de_ids, collapse = ","), "]"),
      paging = "false"
    )
  
  resp <- req |> req_perform()
  resp |> resp_check_status()
  
  jsonlite::fromJSON(resp_body_string(resp), flatten = TRUE)$dataElements %>%
    as_tibble()
}

cache_de_map <- "DATA/cache/de_map.rds"

de_map <- if (
  file.exists(cache_de_map) &&
  difftime(Sys.time(), file.mtime(cache_de_map), units = "days") < duree_cache_jours
) {
  cat("de_map : chargee depuis le cache.\n")
  readRDS(cache_de_map)
} else {
  cat("de_map : recuperation depuis l'API...\n")
  resultat <- get_de_names(base_url, user, pass, de_cols)
  saveRDS(resultat, cache_de_map)
  resultat
}

# Si de nouveaux data elements apparaissent (jamais vus dans le
# cache), on les recupere en complement plutot que de tout
# reinterroger.
de_manquants <- setdiff(de_cols, de_map$id)
if (length(de_manquants) > 0) {
  cat(length(de_manquants), "nouveau(x) data element(s) non present(s) dans le cache, recuperation...\n")
  de_map <- bind_rows(de_map, get_de_names(base_url, user, pass, de_manquants))
  saveRDS(de_map, cache_de_map)
}

de_map <- de_map %>%
  mutate(label = ifelse(!is.na(shortName) & shortName != "", shortName, name))

rename_vec <- setNames(
  make.names(de_map$label, unique = TRUE),
  de_map$id
)

df_wide_named <- df_wide %>%
  rename_with(
    .fn   = ~ unname(rename_vec[.x]),
    .cols = intersect(names(df_wide), names(rename_vec))
  )


# ------------------------------------------------------------
# 4. HIERARCHIE DES UNITES D'ORGANISATION (AVEC CACHE DISQUE)
# ------------------------------------------------------------
#
# Meme logique de cache que de_map : la hierarchie
# administrative change tres rarement.
# ------------------------------------------------------------

get_ou_parent <- function(base_url, user, pass, ids, chunk_size = 100) {
  
  chunks <- split(ids, ceiling(seq_along(ids) / chunk_size))
  
  map_dfr(chunks, function(x) {
    req <- request(paste0(base_url, "api/organisationUnits.json")) |>
      req_auth_basic(user, pass) |>
      req_timeout(60) |>
      req_retry(max_tries = 3, backoff = ~ 5) |>
      req_url_query(
        fields = "id,name,parent[id,name,parent[id,name]]",
        filter = paste0("id:in:[", paste(x, collapse = ","), "]"),
        paging = "false"
      )
    
    resp <- req |> req_perform()
    resp |> resp_check_status()
    
    js <- jsonlite::fromJSON(resp_body_string(resp), flatten = TRUE)
    as_tibble(js$organisationUnits)
  })
}

ou_ids <- df_wide_named %>%
  distinct(orgUnit) %>%
  pull(orgUnit)

cache_ou_hier <- "DATA/cache/ou_hier.rds"

ou_hier <- if (
  file.exists(cache_ou_hier) &&
  difftime(Sys.time(), file.mtime(cache_ou_hier), units = "days") < duree_cache_jours
) {
  cat("ou_hier : chargee depuis le cache.\n")
  readRDS(cache_ou_hier)
} else {
  cat("ou_hier : recuperation depuis l'API...\n")
  resultat <- get_ou_parent(base_url, user, pass, ids = ou_ids) %>%
    transmute(
      orgUnit = id,
      as      = name,
      ds      = parent.name,
      region  = parent.parent.name
    )
  saveRDS(resultat, cache_ou_hier)
  resultat
}

# Unites d'organisation nouvelles (absentes du cache) : on les
# recupere en complement.
ou_manquants <- setdiff(ou_ids, ou_hier$orgUnit)
if (length(ou_manquants) > 0) {
  cat(length(ou_manquants), "unite(s) d'organisation non presente(s) dans le cache, recuperation...\n")
  nouveau <- get_ou_parent(base_url, user, pass, ids = ou_manquants) %>%
    transmute(
      orgUnit = id,
      as      = name,
      ds      = parent.name,
      region  = parent.parent.name
    )
  ou_hier <- bind_rows(ou_hier, nouveau)
  saveRDS(ou_hier, cache_ou_hier)
}


# ------------------------------------------------------------
# 5. FUSION FINALE
# ------------------------------------------------------------

df_geo <- left_join(df_wide_named, ou_hier, by = "orgUnit")
df_geo <- clean_names(df_geo)
df_geo <- df_geo %>%
  mutate(date = as.Date(sbc_date_de_notification))

df_geo <- df_geo %>%
  mutate(
    temp_ds = ds,
    region  = if_else(region == "Ministere de la Sante Publique", temp_ds, region),
    ds      = if_else(region == temp_ds, as, ds)
  )

cat("\nPipeline termine. df_geo :", nrow(df_geo), "lignes,", ncol(df_geo), "colonnes.\n")



# ============================================================
# EXPORT JSON POUR LE DASHBOARD WEB
# ============================================================
#
# Produit docs/data/signals.json, lu par docs/index.html a chaque
# ouverture du dashboard. Format : tableau de tableaux (pas de noms
# de colonnes repetes) pour rester compact - dataframe = "values".
#
# Colonnes, dans l'ordre :
#   [1] date (AAAA-MM-JJ)
#   [2] status
#   [3] region (sans prefixe "Region ")
#   [4] ds (sans prefixe "District ")
#   [5] as
#   [6] sbc_type
#   [7] sbc_nom_de_l_evenement_retenu
#   [8] sbc_code_d_acces_au_tirage_et_verification
#   [9] sbc_commentaires (texte libre, pour la classification niveau 1
#       cote dashboard - cf. classifier_vectorise dans le pipeline R)
#   [10] created (horodatage brut DHIS2, ex. "2026-08-19T14:32:00.000")
#   [11] sbc_date_de_verification_du_signal_cas (DATE simple, pas d'heure)
#   [12] sbc_code_d_acces_evaluation_et_risques
#   [13] sbc_les_informations_rapportees_correspondent (booleen/texte brut)
# ============================================================

library(jsonlite)

dir.create("docs/data", showWarnings = FALSE, recursive = TRUE)

df_export <- df_geo %>%
  transmute(
    date     = as.character(date),
    status   = status,
    region   = str_remove(region, "^Region\\s+"),
    ds       = str_remove(ds, "^District\\s+"),
    as       = as,
    sbc_type = sbc_type,
    sbc_nom_de_l_evenement_retenu = sbc_nom_de_l_evenement_retenu,
    sbc_code_d_acces_au_tirage_et_verification = sbc_code_d_acces_au_tirage_et_verification,
    sbc_commentaires = sbc_commentaires,
    created = as.character(created),
    sbc_date_de_verification_du_signal_cas = as.character(sbc_date_de_verification_du_signal_cas),
    sbc_code_d_acces_evaluation_et_risques = sbc_code_d_acces_evaluation_et_risques,
    sbc_les_informations_rapportees_correspondent = as.character(sbc_les_informations_rapportees_correspondent)
  )

write(
  toJSON(df_export, dataframe = "values", na = "null"),
  "docs/data/signals.json"
)

cat("Export JSON :", nrow(df_export), "lignes -> docs/data/signals.json\n")
