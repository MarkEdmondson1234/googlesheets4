A1_char_class <- "[a-zA-Z0-9:$]"
compound_rx <- glue("(?<sheet>^.+)!(?<cell_range>{A1_char_class}+$)")
letter_part <- "[$]?[A-Za-z]{1,3}"
number_part <- "[$]?[0-9]{1,7}"
A1_rx <- glue("^{letter_part}{number_part}$|^{letter_part}$|^{number_part}$")
A1_decomp <- glue("(?<column>{letter_part})?(?<row>{number_part})?")

lookup_sheet <- function(sheet = NULL, sheets_df, visible = NA) {
  maybe_sheet(sheet)
  if (is.null(sheets_df)) {
    stop_glue("Can't look up, e.g., sheet name or id without sheet metadata")
  }

  if (isTRUE(visible)) {
    sheets_df <- sheets_df[sheets_df$visible, ]
  }

  if (is.null(sheet)) {
    first_sheet <- which.min(sheets_df$index)
    return(as.list(sheets_df[first_sheet, ]))
  }
  # sheet is a string or an integer

  if (is.character(sheet)) {
    sheet <- sq_unescape(sheet)
    m <- match(sheet, sheets_df$name)
    if (is.na(m)) {
      stop_glue("No sheet found with this name: {sq(sheet)}")
    }
    return(as.list(sheets_df[m, ]))
  }
  # sheet is an integer

  m <- as.integer(sheet)
  if (!(m %in% seq_len(nrow(sheets_df)))) {
    stop_glue(
      "There are {nrow(sheets_df)} sheets:\n",
      "  * Requested sheet number is out-of-bounds: {m}"
    )
  }
  as.list(sheets_df[m, ])
}

first_sheet <- function(sheets_df, visible = NA) {
  lookup_sheet(sheet = NULL, sheets_df = sheets_df, visible = visible)
}

first_visible <- function(sheets_df) first_sheet(sheets_df, visible = TRUE)

first_visible_id <- function(sheets_df) {
  first_sheet(sheets_df, visible = TRUE)$id
}

first_visible_name <- function(sheets_df) {
  first_sheet(sheets_df, visible = TRUE)$name
}

lookup_sheet_name <- function(sheet, sheets_df) {
  s <- lookup_sheet(sheet = sheet, sheets_df = sheets_df)
  s$name
}

check_sheet <- function(sheet, nm = deparse(substitute(sheet))) {
  check_length_one(sheet, nm = nm)
  if (!is.character(sheet) && !is.numeric(sheet)) {
    stop_glue(
      "{bt(nm)} must be either character (sheet name) or ",
      "numeric (sheet number):\n",
      "  * {bt(nm)} has class {class_collapse(sheet)}"
    )
  }
  return(sheet)
}

maybe_sheet <- function(sheet = NULL, nm = deparse(substitute(sheet))) {
  if (is.null(sheet)) {
    sheet
  } else {
    check_sheet(sheet, nm = nm)
  }
}

qualified_A1 <- function(sheet_name = NULL, cell_range = NULL) {
  n_missing <- is.null(sheet_name) + is.null(cell_range)
  if (n_missing == 2) {
    return("")
  }
  sep <- if (n_missing == 0) "!" else ""
  # API docs: "For simplicity, it is safe to always surround the sheet name
  # with single quotes."
  as.character(
    glue("{sq_escape(sheet_name) %||% ''}{sep}{cell_range %||% ''}")
  )
}

as_sheets_range <- function(x) {
  stopifnot(inherits(x, what = "cell_limits"))
  # TODO: we don't show people providing sheet name via cell_limits
  #       so I proceed as if sheet is always specified elsewhere
  x$sheet <- NA_character_
  x <- resolve_limits(x)
  limits <- x[c("ul", "lr")]

  if (noNA(unlist(limits))) {
    return(cellranger::as.range(x, fo = "A1"))
  }

  # cellranger::as.range() does the wrong thing for everything below here,
  # i.e. returns NA
  # But we can make valid A1 ranges for the Sheets API in many cases.
  # Until cellranger is capable, we must do it in googlesheets4.

  if (allNA(unlist(limits))) {
    return(NULL)
  }

  row_limits <- map_int(limits, 1)
  col_limits <- map_int(limits, 2)

  if (allNA(col_limits) && noNA(row_limits)) {
    return(paste0(row_limits, collapse = ":"))
  }
  if (allNA(row_limits) && noNA(col_limits)) {
    return(paste0(cellranger::num_to_letter(col_limits), collapse = ":"))
  }

  if (noNA(limits$ul) && sum(is.na(limits$lr)) == 1) {
    ul <- paste0(cellranger::num_to_letter(col_limits[1]), row_limits[1])
    lr <- cellranger::num_to_letter(col_limits[2]) %NA% row_limits[2]
    return(paste0(c(ul, lr), collapse = ":"))
  }

  # if resolve_limits() is doing its job, we should never get here
  stop_glue(
    "Can't express these cell_limits as an A1 range:\n",
    # cell_limits doesn't have a format method :(
    utils::capture.output(print(x))
  )
}

# think of cell_limits like so:
# ul = upper left  |  lr = lower right
# -----------------+------------------
#      start_row              end_row
#      start_col              end_col
# if start is specified, then so must be the end
#
# here we replace end_row or end_col in such cases with an actual number
#
# if provided, sheet_data is a list with two named elements:
#   * `grid_rows` = max row extent
#   * `grid_columns` = max col extent
# probably obtained like so:
# df <- sheets_get()$sheets
# df[df$name == sheet, c("grid_rows", "grid_columns")]
resolve_limits <- function(cell_limits, sheet_data = NULL) {
  # If no sheet_data, use theoretical maxima.
  # Rows: Max number of cells is 5 million. So that must be the maximum
  #       number of rows (imagine a spreadsheet with 1 sheet and 1 column).
  # Columns: Max col is "ZZZ" = cellranger::letter_to_num("ZZZ") = 18278
  MAX_ROW <- sheet_data$grid_rows    %||% 5000000L
  MAX_COL <- sheet_data$grid_columns %||% 18278L

  limits <- c(cell_limits$ul, cell_limits$lr)
  if (noNA(limits) || allNA(limits)) {
    # rectangle is completely specified or completely unspecified
    return(cell_limits)
  }

  rlims <- function(cl) map_int(cl[c("ul", "lr")], 1)
  clims <- function(cl) map_int(cl[c("ul", "lr")], 2)

  # i:j, ?:j, i:?
  if (allNA(clims(cell_limits))) {
    cell_limits$ul[1] <- cell_limits$ul[1] %NA% 1L
    cell_limits$lr[1] <- cell_limits$lr[1] %NA% MAX_ROW
    return(cell_limits)
  }

  # X:Y, ?:Y, X:?
  if (allNA(rlims(cell_limits))) {
    cell_limits$ul[2] <- cell_limits$ul[2] %NA% 1L
    cell_limits$lr[2] <- cell_limits$lr[2] %NA% MAX_COL
    return(cell_limits)
  }

  # complete ul
  cell_limits$ul[1] <- cell_limits$ul[1] %NA% 1L
  cell_limits$ul[2] <- cell_limits$ul[2] %NA% 1L

  if (allNA(cell_limits$lr)) {
    # populate col of lr
    cell_limits$lr[2] <- cell_limits$lr[2] %NA% MAX_COL
  }

  cell_limits
}

## Note: this function is NOT vectorized, x is scalar
as_cell_limits <- function(x) {
  check_character(x)
  check_length_one(x)
  ## match against <sheet name>!<A1 cell reference or range>?
  parsed <- rematch2::re_match(x, compound_rx)

  ## successful match (and parse)
  if (notNA(parsed$`.match`)) {
    cell_limits <- limits_from_range(parsed$cell_range)
    cell_limits$sheet <- parsed$sheet
    return(cell_limits)
  }

  ## failed to match
  ## two possibilities:
  ##   * An A1 cell reference or range
  ##   * Name of a sheet or named region
  if (all(grepl(A1_rx, strsplit(x, split = ":")[[1]]))) {
    limits_from_range(x)
  } else {
    ## TO THINK: I am questioning if this should even be allowed
    ## perhaps you MUST use sheet argument for this, not range?
    ## to be clear: we're talking about passing a sheet name or name of a
    ## named range, without a '!A1:C4' type of range as suffix
    cell_limits(sheet = x)
  }
  ## TODO: above is still not sophisticated enough to detect that
  ## A, AA, AAA (strings of length less than 4) and
  ## 1, 12, ..., 1234567 (numbers with less than 8 digits)
  ## are not, I believe, valid ranges
}

limits_from_range <- function(x) {
  x_split <- strsplit(x, ":")[[1]]
  if (!length(x_split) %in% 1:2)   {stop_glue("Invalid range: {sq(x)}")}
  if (!all(grepl(A1_rx, x_split))) {stop_glue("Invalid range: {sq(x)}")}
  corners <- rematch2::re_match(x_split, A1_decomp)
  if (anyNA(corners$.match))  {stop_glue("Invalid range: {sq(x)}")}
  corners$column <- ifelse(nzchar(corners$column), corners$column, NA_character_)
  corners$row <- ifelse(nzchar(corners$row), corners$row, NA_character_)
  if (nrow(corners) == 1) {
    corners <- corners[c(1, 1), ]
  }
  cellranger::cell_limits(
    ul = c(
      corners$row[1] %NA% NA_integer_,
      cellranger::letter_to_num(corners$column[1]) %NA% NA_integer_
    ),
    lr = c(
      corners$row[2] %NA% NA_integer_,
      cellranger::letter_to_num(corners$column[2]) %NA% NA_integer_
    )
  )
}

check_range <- function(range = NULL) {
  if (is.null(range) ||
      inherits(range, what = "cell_limits") ||
      is_string(range)) return(range)
  stop_glue(
    "{bt('range')} must be NULL, a string, or a {bt('cell_limits')} object."
  )
}

## the `...` are used to absorb extra variables when this is used inside pmap()
make_cell_range <- function(start_row, end_row, start_column, end_column,
                       sheet_name, ...) {
  cl <- cellranger::cell_limits(
    ul = c(start_row, start_column),
    lr = c(end_row, end_column),
    sheet = sq(sheet_name)
  )
  as_sheets_range(cl)
}

## A pair of functions for the (un)escaping of spreadsheet names
## for use in range strings like 'Sheet1'!A2:D4
sq_escape <- function(x) {
  if (is.null(x)) return()
  ## if string already starts and ends with single quote, pass it through
  is_not_quoted <- !map_lgl(x, ~ grepl("^'.*'$", .x))
  ## duplicate each single quote and protect string with single quotes
  x[is_not_quoted] <- paste0("'", gsub("'", "''", x[is_not_quoted]), "'")
  x
}

sq_unescape <- function(x) {
  if (is.null(x)) return()
  ## only modify if string starts and ends with single quote
  is_quoted <- map_lgl(x, ~ grepl("^'.*'$", .x))
  ## strip leading and trailing single quote and substitute 1 single quote
  ## for every pair of single quotes
  x[is_quoted] <- gsub("''", "'", sub("^'(.*)'$", "\\1", x[is_quoted]))
  x
}
