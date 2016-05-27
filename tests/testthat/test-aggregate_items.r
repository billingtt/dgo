data(opinion)
item_data <- opinion
ctrl <- dgirt:::init_control(opinion, item_names = "Q_cces2006_abortion",
                  time_name = "year", geo_name = "state", group_names = "race",
                  time_filter = 2006:2008, geo_filter = c("MA", "NY"),
                  survey_name = "source", weight_name = "weight")

make_group_counts <- function(item_data, aggregate_data, ctrl) {
  # Make a table giving success and trial counts by group and item.
  #
  # Because of how DGIRT Stan code iterates over the data, the result must be
  # ordered by time, item, and then group. The order of the grouping variables
  # doesn't matter so long as it's consistent between here and MMM.
  gt_names <- attr(item_data, "gt_items")
  item_data[, c("n_responses") := list(rowSums(!is.na(.SD))),
            .SDcols = gt_names]
  item_data[, c("def") := lapply(.SD, calc_design_effects),
            .SDcols = ctrl@weight_name, with = FALSE,
            by = c(ctrl@geo_name, ctrl@group_names, ctrl@time_name)]

  # get design-effect-adjusted nonmissing response counts by group and item
  item_n <- item_data[, lapply(.SD, count_items_cpp, get("n_responses"), get("def")),
                      .SDcols = c(gt_names),
                      by = c(ctrl@geo_name, ctrl@group_names, ctrl@time_name)]
  # append _n_grp to the response count columns
  item_n_vars <- paste0(gt_names, "_n_grp")
  names(item_n) <- replace(names(item_n), match(gt_names, names(item_n)), item_n_vars)
  data.table::setkeyv(item_n, c(ctrl@time_name, ctrl@geo_name, ctrl@group_names))
  drop_cols <- setdiff(names(item_n), c(key(item_n), item_n_vars))
  item_n[, c(drop_cols) := NULL, with = FALSE]

  # get mean ystar
  item_data[, c("adj_weight") := get(ctrl@weight_name) / get("n_responses")]
  item_means <- item_data[, lapply(.SD, function(x) weighted_mean(x, .SD$adj_weight)),
                          .SDcols = c(gt_names, "adj_weight"),
                          by = c(ctrl@geo_name, ctrl@group_names, ctrl@time_name)]
  # append _mean to the mean response columns 
  item_mean_vars <- paste0(gt_names, "_mean")
  names(item_means) <- replace(names(item_means), match(gt_names, names(item_means)), item_mean_vars)
  data.table::setkeyv(item_means, c(ctrl@time_name, ctrl@geo_name, ctrl@group_names))
  drop_cols <- setdiff(names(item_means), c(key(item_means), item_mean_vars))
  item_means[, c(drop_cols) := NULL, with = FALSE]

  # join response counts with means 
  count_means <- item_n[item_means]
  count_means <- count_means[, c(ctrl@time_name, ctrl@geo_name,
                                   ctrl@group_names, item_mean_vars,
                                   item_n_vars), with = FALSE]

  # the group success count for an item is the product of its count and mean
  item_s_vars <- paste0(gt_names, "_s_grp")
  count_means[, c(item_s_vars) := round(count_means[, (item_mean_vars), with = FALSE] *
                                         count_means[, (item_n_vars), with = FALSE], 0)]
  count_means <- count_means[, -grep("_mean$", names(count_means)), with = FALSE]


  # we want a long table of successes (s_grp) and trials (n_grp) by group and
  # item; items need to move from columns to rows
  melted <- melt(count_means, id.vars = c(ctrl@time_name, ctrl@geo_name,
                                           ctrl@group_names),
                 variable.name = "item")
  melted[, c("variable") := list(gsub(".*([sn]_grp)$", "\\1", get("item")))]
  melted[, c("item") := list(gsub("(.*)_[sn]_grp$", "\\1", get("item")))]
  f <- as.formula(paste0(paste(ctrl@time_name, ctrl@geo_name,
                               paste(ctrl@group_names, collapse = " + "),
                               "item", sep = "+"), " ~ variable"))
  counts <- data.table::dcast.data.table(melted, f, drop = FALSE, fill = 0L)

  # include aggregates, if any
  if (length(aggregate_data) && nrow(aggregate_data) > 0) {
    counts <- data.table::rbindlist(list(counts, aggregate_data), use.names =
                                    TRUE)
    message("Added ", length(ctrl@aggregate_item_names), " items from aggregate data.")
    data.table::setkeyv(counts, c(ctrl@time_name, "item", ctrl@group_names,
                                  ctrl@geo_name))
  }

  # include unobserved cells
  all_groups = expand.grid(c(setNames(list(ctrl@geo_filter), ctrl@geo_name),
                             setNames(list(ctrl@time_filter), ctrl@time_name),
                             lapply(counts[, c(ctrl@group_names,
                                                     "item"), with = FALSE],
                                    function(x) sort(unique(x)))),
                           stringsAsFactors = FALSE)
  counts <- merge(counts, all_groups, all = TRUE)

  # stan code expects unobserved group-items to be omitted
  counts[is.na(get("s_grp")), c("s_grp") := 0]
  counts[is.na(get("n_grp")), c("n_grp") := 0]

  # create an identifier for use in n_vec and s_vec 
  counts[, c("name") := do.call(paste, c(.SD, sep = "__")), .SDcols =
               c(ctrl@time_name, ctrl@geo_name, ctrl@group_names, "item")]

  setkeyv(counts, c(ctrl@time_name, "item", ctrl@group_names, ctrl@geo_name))
  counts
}
