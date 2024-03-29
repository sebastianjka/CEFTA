library(tidyverse)
setwd("D:/Thesis/Code and data/Thesis")

# use an R project, then whereever you put the *.proj file will be the base path
# and you can then provide all paths relative to whichever directory you are in
# e.g. if you have "D:/something/somethin/myproject.proj" then you can just 
# write "Data/labels_FD.txt" instead of "D:/something/somethin/Data/labels_FD.txt"
# which also makes it easier to pass the project to others.

# Labels -----------------------------------------------------------------------

# First set up FD labels
labels_FD <- read_delim("Data/Eora/labels_FD.txt",
                        delim = "\t",  # tab separator
                        col_names = c("country", "use"),
                        col_type = "-c-c-") # 2nd & 4th column as character
col_labels_FD <- paste0(labels_FD$country, 27:32)

labels_T <- read_delim("Data/Eora/labels_T1.txt", 
                       delim = "\t",
                       col_names = c("country", "sector"),
                       col_types = "-c-c-")
# put everything that goes to ROW into final consumption (27)
col_labels_T <- c(paste0(labels_T$country, 1:26)[1:4914], "ROW27") 

# just add all years here to run this as a loop
for(year_n in c(1990:2015)) {
    
  # Final Demand ---------------------------------------------------------------
  
  # now read in data
  FD <- read_delim(paste0("Data/Eora/Eora26_", year_n, "_bp_FD.txt"), 
                   delim = "\t",
                   col_names = col_labels_FD,
                   col_types = paste0(rep("n", 1140), collapse = ""))
  # add row definitions
  FD <- FD %>%
    mutate(country = c(rep(unique(labels_FD$country)[-190], each = 26), "ROW"),
           sector = as.integer(c(rep(1:26, 189), 0))) # 0 for ROW total 
  
  # and get into tidy format (takes a bit)
  FD <- FD %>%
    pivot_longer(c(-country, -sector), 
                 names_to = "importer_use",
                 values_to = "flow") %>% 
    separate(importer_use, into = c("importer", "use"), sep = 3) %>%
    mutate(use = as.integer(use))
  
  # Intermediate ---------------------------------------------------------------
  
  Tdata <- read_delim(paste0(paste0("Data/Eora/Eora26_", year_n, "_bp_T.txt")),
                      delim = "\t",
                      col_names = col_labels_T,
                      col_types = paste0(rep("n", 4915), collapse = ""))
  
  # add row definitions
  Tdata <- Tdata %>%
    mutate(country = c(rep(unique(labels_T$country)[-190], each = 26), "ROW"),
           sector = as.integer(c(rep(1:26, 189), 0))) # 0 for ROW total 
  
  # and get into tidy format (takes a bit)
  Tdata <- Tdata %>%
    pivot_longer(c(-country, -sector), 
                 names_to = "importer_use",
                 values_to = "flow") %>% 
    separate(importer_use, into = c("importer", "use"), sep = 3) %>%
    mutate(use = as.integer(use))
  
  # combine both
  wiot <- bind_rows(FD, Tdata)
  
  # all FD flows to ROW are 0 - is this like that in all years?
  # all T flows to ROW have been assigned to final consumption (27)
  # Due to the latter flows from any country to ROW27 exist twice now in the wiot
  # data frame and I aggregate them (takes a bit to run)
  wiot <- wiot %>% 
    # I add an extra step here (and below with 2.) to speed up things as 
    # grouping the large data_frame with almost one group per row would be very
    # slow
    filter(importer == "ROW") %>% 
    group_by(country, sector, importer, use) %>% 
    summarise(flow = sum(flow), .groups = "drop") %>% 
    bind_rows(wiot %>% filter(importer != "ROW")) # 2.
  
  # ROW fix --------------------------------------------------------------------
  
  # calculate average input mix (across sectors) for each importer and use 
  # category w/o ROW
  input_mix <- wiot %>% 
    filter(country != "ROW") %>%  # get rid of ROW
    group_by(importer, use, sector) %>% 
    summarise(flow = sum(flow),
              .groups = "drop_last") %>% # regroups by importer use 
    mutate(input_share = ifelse(flow != 0,  # ifelse to avoid division by 0
                                flow / sum(flow),
                                0)) %>% 
    ungroup %>% 
    select(importer, use, sector, input_share)
  
  # Get part of wiot with ROW as exporter and export sector = 0 (total)
  wiot_row <- filter(wiot, country == "ROW")
  # use the above input shares to split these values
  wiot_row <- wiot_row %>% 
    select(-sector) %>% 
    left_join(input_mix, by = c("importer", "use")) %>% 
    mutate(flow = flow * input_share) %>% 
    select(-input_share)
  
  # and attach to wiot
  wiot <- filter(wiot, country != "ROW") %>% 
    bind_rows(wiot_row)
  
  # we have alread assigned all of ROW's imports to final consumption (27) so 
  # we can not get negative VAD in ROW, so now we can set all remaining missing
  # flows (ROW with itself and ROW intermediate imports) to 0
  wiot <- complete(wiot, 
                   country, sector, importer, use, 
                   fill = list("flow" = 0))
  
  # ILO fix --------------------------------------------------------------------
  
  # this is much easier in tidy format:
  extra_countries <- c("AND", "ATG", "ABW", "BMU", "VGB", "CYM", "GRL", "LIE",
                       "MCO", "ANT", "SMR", "SYC", "USR", "IRN", "ROW")
  
  # I added Iran as the numbers there are just not believable and lead to very
  # large negative vad in IRN
  
  wiot <- wiot %>% 
    mutate(country = ifelse(country %in% extra_countries, "ROW", country),
           importer = ifelse(importer %in% extra_countries, "ROW", importer)) 
  wiot <- wiot %>% 
    filter(country == "ROW" | importer == "ROW") %>% # same as above, for speed
    group_by(country, importer, sector, use) %>% 
    summarise(flow = sum(flow), .groups = "drop") %>% 
    bind_rows(wiot %>% filter(country != "ROW" & importer != "ROW"))
  
  # Gravity --------------------------------------------------------------------
  
  # For the Gravity estimation you best work with the observed trade flows, i.e.
  # there is no need to perform neither the vad adjutment nor the inventory fix
  # you only need to to this for the one I-O-Table that you use as the baseline
  # for your simulation (likely the most current)
  
  saveRDS(wiot, paste0("wiot_", year_n, "_gravity.rds"))
  
  # Gravity continues in second script
} # end of for loop

# clean up some large data
rm(Tdata, FD, input_mix, wiot_row)

# Calibration of Simulation %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

# if you alread ran the above you can just start here with
wiot <- readRDS("wiot_2015_gravity.rds")

# For the simulation we take the most recent IO table (the last one calculated
# in the loop) and continue

# IRN has unreliable number which lead to large negative value added. We avoid
# this by assigning all flows into ROW to final consumption (we did this above
# but before adding third countries to ROW, so now I need to do it again. Doing
# this in the right order above would make more sense but I do not want to rerun
# everything)

wiot <- wiot %>% 
  group_by(country, importer, sector) %>% 
  mutate(flow = ifelse(importer == "ROW" & use == 27, sum(flow), flow),
         flow = ifelse(importer == "ROW" & use != 27, 0, flow)) %>% 
  ungroup

# Remove negative vad ==========================================================

# this is an updated version of the previous function
remove_negative_vad <- function(iot, category_to_scale) {
  
  location_sector_stats <- iot %>% 
    group_by(country, sector) %>% 
    mutate(output = sum(flow)) %>% 
    group_by(importer, use) %>% 
    mutate(intermediate_use = sum(flow)) %>% 
    ungroup %>% 
    filter(country == importer, sector == use) %>% 
    mutate(imputed_vad = output - intermediate_use) %>% 
    select(-importer, -use, -flow)
  
  vad_fix <- location_sector_stats %>% 
    mutate(vad_shr = imputed_vad / output,
           new_output = ifelse(imputed_vad > 0, 
                               output, 
                               intermediate_use / 
                                 (1 - min(vad_shr[imputed_vad > 0]))),
           output_diff = new_output - output) %>% 
    filter(vad_shr < 0)
  
  if(nrow(vad_fix) == 0) {
    message("No negative VAD imputed. Returning the table unchanged.")
    return(iot)
  } else {
    message("Negative VAD imputed in \n",
            paste0(capture.output(select(vad_fix, country, sector))[-c(1,3)],
                   collapse = "\n"),
            "\n Recalculating table.")
    
    changed_data <- iot %>% 
      inner_join(vad_fix, by = c("country", "sector")) %>% 
      filter(use == category_to_scale) %>% 
      group_by(country, sector) %>% 
      mutate(flow = flow * (sum(flow) + output_diff) / sum(flow)) %>% 
      ungroup %>% 
      select(country, sector, importer, use, flow)
    
    iot <- iot %>% 
      anti_join(changed_data, 
                by = c("country", "sector", "importer", "use")) %>% 
      bind_rows(changed_data) 
    
    return(iot) 
  }
}

wiot <- remove_negative_vad(wiot, 27)

# remove inventory changes =====================================================

remove_dynamic_categories <- function(iot,
                                      dynamic_categories,
                                      category_to_scale) {
  
  n_locations <- iot$country %>% unique() %>% length()
  n_sectors <- max(iot$sector)
  first_final_use_category <- n_sectors + 1
  n_use_categories <- max(iot$use)
  
  # Coefficient Matrix --------------------------------------------------------- 
  
  # get matrix of only intermediate goods trade
  intermediate_matrix <-  iot %>% 
    filter(use < first_final_use_category) %>% 
    arrange(importer, use, country, sector) %>%
    pull(flow) %>% 
    matrix(nrow = n_locations * n_sectors)
  
  # get a vector of total output (revenue) by country and sector
  output <- iot %>%
    group_by(country, sector) %>% 
    summarise(flow = sum(flow), .groups = "drop") %>% 
    # make sure things are in the same order as for the matrix x
    arrange(country, sector) %>% 
    pull(flow)
  
  # coefficient matrix, divide by a small number to prevent infinity
  coefficient_matrix <- intermediate_matrix / 
    rep(replace(output, output == 0, 0.000001), 
        each = nrow(intermediate_matrix))
  
  # Leontief-inverse to calculate new x given the constructed new demand -------
  leontief_inverse <- diag(nrow(coefficient_matrix)) - coefficient_matrix
  
  # aggregate new demand vector for each country-sector output
  new_demand <- iot %>% 
    filter(use > n_sectors) %>%
    mutate(flow = ifelse(use %in% dynamic_categories & flow < 0, 0, flow),
           use = ifelse(use %in% dynamic_categories, category_to_scale, use),
           use = first_final_use_category - 1 + as.integer(as.factor(use))) %>%
    group_by(country, sector, importer, use) %>% 
    summarise(flow = sum(flow), .groups = "drop")
  
  new_total_demand <- new_demand %>% 
    group_by(country, sector) %>%
    summarise(demand = sum(flow), .groups = "drop") %>% 
    # make sure things are in the same order as in x
    arrange(country, sector) %>% 
    pull(demand)
  
  # update
  new_output <- solve(leontief_inverse, new_total_demand)
  new_intermediate_matrix <-  coefficient_matrix %*% diag(new_output)
  
  # bring everything back into "long" format -----------------------------------
  
  new_iot <- iot %>%  
    filter(use < first_final_use_category) %>% 
    arrange(importer, use, country, sector) %>%
    mutate(flow = as.vector(new_intermediate_matrix)) %>% 
    bind_rows(new_demand)
  
  return(new_iot)
}

# category 31 (inventory) can have negative flow values, we remove it according
# to Costinot & Rodriguez-Clare 2014 ("Trade Theory with Numbers")
# takes a minute
wiot <- remove_dynamic_categories(wiot, 31, 27)

# Demand =======================================================================

# Finally we can add up all final demand categories
wiot <- wiot %>% 
  mutate(use = ifelse(use > 27, 27, use)) %>% 
  group_by(country, importer, sector, use) %>% 
  summarise(flow = sum(flow), .groups = "drop")

# This is the final WIOT that can be used for calibration now - no negative 
# flows, no negative vad

saveRDS(wiot, "wiot_simulation.rds")