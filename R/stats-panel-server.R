prepare_admin_panel_components <- function(input, output, session, db_config_list) {
  hour_levels <- c("12am", paste0(1:11, "am"), "12pm", paste0(1:11, "pm"))

  log_data <- reactive({
    db <- connect_to_db(db_config_list)
    query <- sprintf(
      "SELECT * FROM user_log WHERE date(time) >= '%s' AND date(time) <= '%s'",
      input$date_from, input$date_to
    )
    selected_log_data <- odbc::dbGetQuery(db, query) %>% {
      if (nrow(.) > 0) dplyr::mutate(., date = as.Date(time)) else req(FALSE)
    }
    odbc::dbDisconnect(db)
    selected_log_data
  })

  session_details <- reactive({
    db <- connect_to_db(db_config_list)
    query <- sprintf(
      "SELECT * FROM session_details WHERE date(time) >= '%s' AND date(time) <= '%s'",
      input$date_from, input$date_to
    )
    selected_session_details <- odbc::dbGetQuery(db, query) %>%
      dplyr::select(session, detail) %>%
      dplyr::group_by(session) %>%
      dplyr::summarise(title = paste(detail, collapse = " | "))

    odbc::dbDisconnect(db)
    selected_session_details
  })

  dt_options <- list(
    lengthChange = FALSE,
    pageLength = 8
  )

  dt_options_no_search <- list(
    lengthChange = FALSE,
    pageLength = 8,
    searching = FALSE
  )

  output$filters <- renderUI({
    tagList(
      tags$div(
        tags$div(HTML("From")),
        shiny.semantic::date_input("date_from", value = Sys.Date() - 30, icon = NULL, style = "width: 135px;")
      ),
      tags$div(
        tags$div(HTML("To")),
        shiny.semantic::date_input("date_to", value = Sys.Date(), icon = NULL, style = "width: 135px;")
      )
    )
  })

  selected_log_data <- reactive({
    shiny::validate(
      need(input$date_from, label = "date_from"),
      need(input$date_to, label = "date_to")
    )
    log_data()
  })

  output$download_data <- downloadHandler(
    filename = function() {
      sprintf("data_%s_%s.csv", input$date_from, input$date_to)
    },
    content = function(file) {
      write.csv(selected_log_data(), file)
    }
  )

  output$date_header <- renderUI({
    tags$h4(class = "ui horizontal divider header", sprintf("From %s to %s", input$date_from, input$date_to))
  })
  ## general tab reactives

  date_base <- reactive({
    shiny::validate(
      need(input$date_from, label = "date_from"),
      need(input$date_to, label = "date_to")
    )
    data.frame(date = seq(as.Date(input$date_from), as.Date(input$date_to), by = "day"))
  })

  date_base_with_hours <- reactive({
    expand.grid(
      date = date_base()$date,
      day_hour = c(paste0(1:12, "am"), paste0(1:12, "pm")),
      stringsAsFactors = FALSE
    )
  })

  ### stats per day:

  users_per_day <- reactive({
    selected_log_data() %>%
      dplyr::select(date, username) %>%
      dplyr::distinct() %>%
      dplyr::select(date) %>%
      dplyr::group_by(date) %>%
      dplyr::summarise(users = n())
  })

  sessions_per_day <- reactive({
    selected_log_data() %>%
      dplyr::select(date, session) %>%
      dplyr::distinct() %>%
      dplyr::select(date) %>%
      dplyr::group_by(date) %>%
      dplyr::summarise(sessions = n())
  })

  time_per_day <- reactive({
    selected_log_data() %>%
      dplyr::mutate(time = as.POSIXct(time)) %>%
      dplyr::group_by(date, session) %>%
      dplyr::summarise(time = round(as.numeric(max(time) - min(time), units = "hours"), 2)) %>%
      dplyr::group_by(date) %>%
      dplyr::summarise(time = mean(time))
  })

  actions_per_day <- reactive({
    selected_log_data() %>%
      dplyr::filter(!(action %in% c("login", "logout"))) %>%
      dplyr::select(date, action) %>%
      dplyr::select(date) %>%
      dplyr::group_by(date) %>%
      dplyr::summarise(actions = n())
  })

  per_day_data <- reactive({
    users_per_day() %>%
      dplyr::full_join(sessions_per_day(), by = "date") %>%
      dplyr::full_join(time_per_day(), by = "date") %>%
      dplyr::full_join(actions_per_day(), by = "date")
  })

  per_day_plot_data <- reactive({
    dplyr::left_join(date_base(), per_day_data(), by = "date") %>%
      tidyr::gather(statistic, value, -date) %>%
      tidyr::replace_na(list(value = 0)) %>%
      dplyr::mutate(id = dplyr::case_when(
        statistic == "users" ~ 3L,
        statistic == "actions" ~ 1L,
        statistic == "sessions" ~ 1L,
        statistic == "time" ~ 2L
      )) %>%
      dplyr::mutate(statistic = dplyr::case_when(
        statistic == "users" ~ "logged users (unique)",
        statistic == "actions" ~ "total clicks and inputs",
        statistic == "sessions" ~ "total opened sessions",
        statistic == "time" ~ "avg session time (hours)"
      ))
  })

  output$daily_stats <- plotly::renderPlotly({
    n_plots <- length(unique(per_day_plot_data()$id))
    x_axis_ticks <- prepare_date_axis_ticks(unique(per_day_plot_data()$date))
    x_date <-
      per_day_plot_data() %>%
      plotly::plot_ly(
        x = ~date, y = ~value, color = ~statistic,
        colors = c("#fbbd08", "#b21e1e", "#00827c", "#1a69a4"), yaxis = ~paste0("y", id)
      ) %>%
      plotly::add_bars() %>%
      plotly::subplot(nrows = n_plots, shareX = TRUE) %>%
      plotly::layout(
        legend = list(orientation = "h"),
        xaxis = list(
          title = "", hoverformat = "%b %d",
          tickvals = x_axis_ticks$tickvals, ticktext = x_axis_ticks$ticktext
        ),
        margin = list(r = 20),
        annotations = list(
          list(
            y = 1.03, text = "Unique users / opened sessions", showarrow = F, xref = "paper", yref = "paper",
            font = list(size = 16)
          ),
          list(
            y = 0.65, text = "Average session time [hours]", showarrow = F, xref = "paper", yref = "paper",
            font = list(size = 16)
          ),
          list(
            y = 0.29, text = "Total clicks and inputs", showarrow = F, xref = "paper", yref = "paper",
            font = list(size = 16)
          )
        )
      ) %>%
      plotly::config(displayModeBar = F)
  })

  time_daily <- reactive({
    selected_log_data() %>%
      dplyr::mutate(time = as.POSIXct(time)) %>%
      dplyr::group_by(session, date) %>%
      dplyr::summarise(time_spent = difftime(max(time), min(time), units = "secs"))
  })

  observe({
    if (length(time_daily()) > 0) {
      output$total_time <- semantic.dashboard::renderValueBox({
        time_hours <- time_daily() %>%
          dplyr::pull(time_spent) %>%
          mean() %>%
          convert_timediff_to_HM()

        semantic.dashboard::valueBox(
          value = time_hours,
          subtitle = "Average time spent on app daily",
          icon = semantic.dashboard::icon("User Circle"),
          color = "yellow",
          width = 16
        )
      })
    } else {
      NULL
    }
  })

  observe({
    if (nrow(selected_log_data()) > 0) {
      output$total_users <- semantic.dashboard::renderValueBox({
        semantic.dashboard::valueBox(
          value = length(unique(selected_log_data() %>% dplyr::filter(username != "") %>% dplyr::pull(username))),
          subtitle = "Unique users accessed app",
          icon = semantic.dashboard::icon("User Circle"),
          color = "red",
          width = 16
        )
      })

      output$total_sessions <- semantic.dashboard::renderValueBox({
        semantic.dashboard::valueBox(
          value = length(unique(selected_log_data() %>% dplyr::pull(session))),
          subtitle = "Sessions opened",
          icon = semantic.dashboard::icon("User Circle"),
          color = "blue",
          width = 16
        )
      })

      output$total_days <- semantic.dashboard::renderValueBox({
        semantic.dashboard::valueBox(
          value = length(unique(as.Date(selected_log_data()$time))),
          subtitle = "Days of active app usage",
          icon = semantic.dashboard::icon("Calendar"),
          color = "teal",
          width = 16
        )
      })
    } else {
      NULL
    }
  })

  ## users tab reactives

  users_plot_data <- reactive({
    total_users_per_day <- selected_log_data() %>%
      dplyr::select(date, username) %>%
      dplyr::distinct() %>%
      dplyr::group_by(date) %>%
      dplyr::summarise(users = n())

    nested_users_data <- tibble::as.tibble(selected_log_data()) %>%
      dplyr::group_by(date) %>%
      tidyr::nest(username)

    new_users <- purrr::map(nested_users_data$data, function(x) unique(unlist(x))) %>% {
      Reduce(union, ., accumulate = TRUE)
    } %>%
      purrr::map(length) %>% {
        c(.[[1]], diff(unlist(.)))
      }

    nested_users_data %>%
      dplyr::select(-data) %>%
      dplyr::mutate(new_users = new_users) %>%
      dplyr::full_join(total_users_per_day, by = "date") %>%
      dplyr::full_join(date_base(), by = "date") %>%
      tidyr::replace_na(list(users = 0, new_users = 0)) %>%
      dplyr::mutate(previous_users = users - new_users)
  })

  active_users <- reactive({
    selected_log_data() %>%
      dplyr::select(time, username, date) %>%
      dplyr::mutate(day_hour = convert_hour(time)) %>%
      dplyr::group_by(date, day_hour) %>%
      dplyr::summarise(users = length(unique(username))) %>%
      dplyr::arrange(date)
  })

  heatmap_data <- reactive({
    heatmap_temp_data <- dplyr::left_join(date_base_with_hours(), active_users(), by = c("date", "day_hour")) %>%
      tidyr::replace_na(list(users = 0))
    heatmap_temp_data$day_hour <- factor(
      heatmap_temp_data$day_hour,
      levels = hour_levels
    )
    heatmap_temp_data
  })

  output$users_general <- plotly::renderPlotly({
    x_axis_ticks <- prepare_date_axis_ticks(unique(users_plot_data()$date))
    plotly::plot_ly(dplyr::arrange(users_plot_data(), date),
            x = ~date, y = ~new_users, color = I("#ff7f0e"),
            name = "New users logged", type = "bar",
            hoverinfo = "text", text = ~paste("New users:", new_users)
    ) %>%
      plotly::add_trace(
        y = ~previous_users, name = "Returning users logged", color = I("#1f77b4"),
        hoverinfo = "text", text = ~paste("Returning users:", previous_users)
      ) %>%
      plotly::layout(
        yaxis = list(title = ""),
        xaxis = list(
          title = "", hoverformat = "%b %d",
          tickvals = x_axis_ticks$tickvals, ticktext = x_axis_ticks$ticktext
        ),
        title = "Users logged each day", barmode = "stack"
      ) %>%
      plotly::config(displayModeBar = F)
  })

  output$users_per_hour <- plotly::renderPlotly({
    colz <- prepare_color_scale(heatmap_data()$users, "Blues")
    x_axis_ticks <- prepare_date_axis_ticks(unique(heatmap_data()$date))
    plotly::plot_ly(heatmap_data(),
            x = ~date, y = ~day_hour, z = ~users,
            type = "heatmap", colorscale = colz, showscale = FALSE, hoverinfo = "text",
            text = ~paste(
              "Date:", date,
              "</br>Hour:", day_hour,
              "</br>Users: ", users
            )
    ) %>%
      plotly::layout(
        title = "Total users logged each hour", yaxis = list(title = ""),
        xaxis = list(
          title = "", hoverformat = "%b %d",
          tickvals = x_axis_ticks$tickvals, ticktext = x_axis_ticks$ticktext
        )
      ) %>%
      plotly::config(displayModeBar = F)
  })

  output$selected_user <- renderUI({
    shiny.semantic::search_selection_choices("selected_users", sort(unique(selected_log_data()$username)),
                             multiple = FALSE, default_text = "Select user"
    )
  })

  selected_user_data <- reactive({
    shiny::validate(
      need(input$selected_users, "At least one user must be selected")
    )
    selected_log_data() %>%
      dplyr::filter(username %in% input$selected_users)
  })

  actions_per_users_data <- reactive({
    temp_user_actions_data <- selected_user_data() %>%
      dplyr::mutate(day_hour = convert_hour(time)) %>%
      dplyr::group_by(date, day_hour) %>%
      dplyr::summarise(actions = n())

    temp_user_actions_data <- dplyr::left_join(date_base_with_hours(), temp_user_actions_data, by = c("date", "day_hour")) %>%
      tidyr::replace_na(list(actions = 0))

    temp_user_actions_data$day_hour <- factor(
      temp_user_actions_data$day_hour,
      levels = hour_levels
    )
    temp_user_actions_data
  })

  output$user_actions <- plotly::renderPlotly({
    colz <- prepare_color_scale(actions_per_users_data()$actions, "Blues")
    x_axis_ticks <- prepare_date_axis_ticks(unique(actions_per_users_data()$date))
    plotly::plot_ly(actions_per_users_data(),
            x = ~date, y = ~day_hour, z = ~actions,
            type = "heatmap", colorscale = colz, showscale = FALSE, hoverinfo = "text",
            text = ~paste(
              "Date:", date,
              "</br>Hour:", day_hour,
              "</br>Actions: ", actions
            )
    ) %>%
      plotly::layout(
        yaxis = list(title = ""), title = "Operations performed by user each hour",
        xaxis = list(
          title = "", hoverformat = "%b %d",
          tickvals = x_axis_ticks$tickvals, ticktext = x_axis_ticks$ticktext
        ),
        margin = list(r = 25, b = 50)
      ) %>%
      plotly::config(displayModeBar = F)
  })

  output$user_total_time <- semantic.dashboard::renderValueBox({
    total_hours <- selected_user_data() %>%
      dplyr::mutate(time = as.POSIXct(time)) %>%
      dplyr::group_by(session) %>%
      dplyr::summarise(time_spent = difftime(max(time), min(time), units = "secs")) %>%
      dplyr::pull(time_spent) %>%
      sum() %>%
      convert_timediff_to_HM()

    semantic.dashboard::valueBox(
      value = total_hours,
      subtitle = "Hours the user spent on app",
      icon = semantic.dashboard::icon("Calendar"),
      color = "blue",
      width = 16
    )
  })

  output$user_active_days <- semantic.dashboard::renderValueBox({
    semantic.dashboard::valueBox(
      value = length(unique(selected_user_data()$date)),
      subtitle = "Days the user logged",
      icon = semantic.dashboard::icon("Calendar"),
      color = "blue",
      width = 16
    )
  })

  output$user_actions_mean <- semantic.dashboard::renderValueBox({
    semantic.dashboard::valueBox(
      value = nrow(selected_user_data()),
      subtitle = "Actions the user executed",
      icon = semantic.dashboard::icon("Calendar"),
      color = "blue",
      width = 16
    )
  })

  output$user_since <- semantic.dashboard::renderInfoBox({
    semantic.dashboard::valueBox(
      value = min(selected_user_data()$date),
      subtitle = "User first login",
      icon = semantic.dashboard::icon("Calendar"),
      color = "blue",
      width = 16
    )
  })

  output$selected_user_stats <- renderUI({
    shiny::validate(need(input$selected_users, "selected_users"))
    if (is.null(input$selected_users)) {
      ""
    } else {
      div(
        class = "ui horizontal segments",
        div(
          class = "ui segment",
          div(
            class = "ui grid",
            div(
              class = "column eleven wide",
              plotly::plotlyOutput("user_actions")
            ),
            div(
              style = "margin-top: 1.8em;", class = "column five wide",
              div(semantic.dashboard::valueBoxOutput("user_total_time"), style = "margin-bottom: 0.5em;"),
              div(semantic.dashboard::valueBoxOutput("user_active_days"), style = "margin-bottom: 0.5em;"),
              div(semantic.dashboard::valueBoxOutput("user_actions_mean"), style = "margin-bottom: 0.5em;"),
              div(semantic.dashboard::valueBoxOutput("user_since"), style = "margin-bottom: 0.5em;")
            )
          )
        )
      )
    }
  })

  # input stats

  global_action_data <- reactive({
    action_date_base <- expand.grid(date = date_base()$date, action = c("input", "click"), stringsAsFactors = FALSE)

    selected_log_data() %>%
      dplyr::filter(action %in% c("input", "click")) %>%
      dplyr::group_by(action, date) %>%
      dplyr::summarise(times = n()) %>% {
        dplyr::left_join(action_date_base, ., by = c("action", "date"))
      } %>%
      tidyr::replace_na(list(times = 0))
  })

  output$global_action_plot <- plotly::renderPlotly({
    colz <- prepare_color_scale(global_action_data()$times, "Blues")
    x_axis_ticks <- prepare_date_axis_ticks(unique(global_action_data()$date))
    plotly::plot_ly(global_action_data(),
            x = ~date, y = ~action, z = ~times,
            type = "heatmap", colorscale = colz, showscale = FALSE, hoverinfo = "text",
            text = ~paste(
              "Date:", date,
              "</br>Action:", action,
              "</br>Amount: ", times
            )
    ) %>%
      plotly::layout(
        title = "Total actions performed each day", yaxis = list(title = ""),
        xaxis = list(
          title = "", hoverformat = "%b %d",
          tickvals = x_axis_ticks$tickvals, ticktext = x_axis_ticks$ticktext
        )
      ) %>%
      plotly::config(displayModeBar = F)
  })

  output$total_inputs <- semantic.dashboard::renderValueBox({
    total_inputs_value <- global_action_data() %>%
      dplyr::filter(action == "input") %>%
      dplyr::pull(times) %>%
      sum()

    semantic.dashboard::valueBox(
      value = total_inputs_value,
      subtitle = "Total inputs performed",
      icon = icon("bar chart"),
      color = "purple",
      width = 5
    )
  })

  output$total_clicks <- semantic.dashboard::renderValueBox({
    total_clicks_value <- global_action_data() %>%
      dplyr::filter(action == "click") %>%
      dplyr::pull(times) %>%
      sum()

    semantic.dashboard::valueBox(
      value = total_clicks_value,
      subtitle = "Total clicks performed",
      icon = icon("bar chart"),
      color = "purple",
      width = 5
    )
  })

  output$select_action <- renderUI({
    actions <- selected_log_data() %>%
      dplyr::filter(action %in% c("click", "input")) %>%
      dplyr::pull(action) %>%
      unique() %>%
      sort()
    shiny.semantic::search_selection_choices("selected_action", actions, multiple = FALSE, default_text = "...")
  })

  selected_action_data <- reactive({
    selected_log_data() %>%
      dplyr::filter(action == input$selected_action)
  })

  selected_action_aggregated_data <- reactive({
    selected_action_data() %>%
      dplyr::group_by(id) %>%
      dplyr::summarise(times_total = n())
  })

  output$selected_action_plot <- plotly::renderPlotly({
    id_date_base <- expand.grid(
      date = date_base()$date, id = unique(selected_action_data()$id),
      stringsAsFactors = FALSE
    )
    x_axis_ticks <- prepare_date_axis_ticks(unique(id_date_base$date))

    id_data <- selected_action_data() %>%
      dplyr::group_by(date, id) %>%
      dplyr::summarise(times = n()) %>% {
        dplyr::left_join(id_date_base, ., by = c("id", "date"))
      } %>%
      dplyr::left_join(selected_action_aggregated_data()) %>%
      tidyr::replace_na(list(times = 0)) %>%
      dplyr::mutate(input_label = sprintf("%s (total %s)", id, times_total))

    colz <- prepare_color_scale(heatmap_data()$users, "Blues")

    plotly::plot_ly(id_data,
            x = ~date, y = ~input_label, z = ~times,
            type = "heatmap", colorscale = colz, showscale = FALSE, hoverinfo = "text",
            text = ~paste(
              "Date:", date,
              "</br>Input ID:", id,
              "</br>Amount: ", times
            )
    ) %>%
      plotly::layout(
        title = "Actions executed each day", yaxis = list(title = ""),
        xaxis = list(
          title = "", hoverformat = "%b %d",
          tickvals = x_axis_ticks$tickvals, ticktext = x_axis_ticks$ticktext
        ),
        margin = list(l = 150)
      ) %>%
      plotly::config(displayModeBar = F)
  })

  output$select_action_id <- renderUI({
    shiny::validate(need(input$selected_action, "selected_action"))
    if (input$selected_action == "input") {
      shiny.semantic::search_selection_choices("selected_action_id", sort(unique(selected_action_data()$id)),
                               multiple = FALSE, default_text = "Select action id"
      )
    } else {
      ""
    }
  })

  selected_action_id_data <- reactive({
    shiny::validate(need(input$selected_action_id, "selected action id"))
    selected_action_data() %>%
      dplyr::filter(id == input$selected_action_id)
  })

  output$action_stats <- renderUI({
    shiny::validate(need(input$selected_action, "selected_action"))
    if (is.null(input$selected_action) | input$selected_action == "") {
      ""
    } else {
      div(class = "sixteen wide column", plotly::plotlyOutput("selected_action_plot", height = "200px"))
    }
  })

  output$input_id_table <- DT::renderDataTable({
    shiny::validate(need(input$selected_action_id, "selected_action_id"))
    selected_action_id_data() %>%
      dplyr::group_by(value) %>%
      dplyr::summarise(times = n()) %>%
      magrittr::set_colnames(c("Value of selected input", "Total Amount"))
  },
  rownames = FALSE,
  options = list(
    lengthChange = FALSE,
    searching = TRUE
  )
  )

  output$action_id_stats <- renderUI({
    shiny::validate(need(input$selected_action, "selected_action"))
    if (input$selected_action == "input") {
      segment(
        title = "Stats per input id",
        tags$h3("Select input ID:"),
        uiOutput("select_action_id", style = "margin-bottom: 0.5em;"),
        DT::dataTableOutput("input_id_table")
      )
    } else {
      ""
    }
  })

  # sessions stats

  sessions_data <- reactive({
    selected_log_data() %>%
      dplyr::select(time, session, action) %>%
      dplyr::filter(action %in% c("login", "logout", "input", "click")) %>%
      dplyr::distinct() %>%
      dplyr::group_by(session) %>%
      dplyr::summarise(
        start = as.character(min(time)), end = as.character(max(time)),
        style = "font-size: 0.1em;"
      ) %>%
      dplyr::left_join(session_details(), by = "session")
  })

  output$sessions_general <- timevis::renderTimevis({
    timevis::timevis(sessions_data(), options = list(
      start = as.POSIXct(sprintf("%s 00:00:00", Sys.Date())),
      end = as.POSIXct(Sys.time()),
      margin = list(item = 0.5)
    ))
  })

  sessions_summary <- reactive({
    selected_log_data() %>%
      dplyr::group_by(session) %>%
      dplyr::summarise(
        username = unique(username),
        session_start_date = min(time),
        session_duration = round(difftime(max(time), min(time), units = "secs")),
        session_actions = n()
      )
  })

  output$sessions_table <- DT::renderDataTable({
    DT::datatable(sessions_summary(),
                  selection = "single",
                  colnames = c("Session ID", "User name", "Init time", "Duration (s)", "Performed actions")
    )
  })

  selected_session <- reactive({
    shiny::validate(need(input$sessions_table_rows_selected, label = "select_row"))
    sessions_summary()[input$sessions_table_rows_selected, ]$session
  })

  selected_session_data <- reactive({
    shiny::validate(need(selected_session(), label = "selected_session"))
    selected_log_data() %>%
      dplyr::filter(action %in% c("login", "logout", "input", "click"), session == selected_session()) %>%
      dplyr::mutate(
        start = as.character(time),
        content = dplyr::case_when(
          action %in% c("login", "logout") ~ action,
          action == "input" ~ sprintf("Input: %s <br /> Value: %s", id, value),
          action == "click" ~ sprintf("Clicked: %s", id)
        ),
        style = "text-align: left;",
        end = NA
      ) %>%
      dplyr::select(start, content, time)
  })

  output$session_actions <- timevis::renderTimevis({
    shiny::validate(need(selected_session_data(), label = "selected_session"))
    timevis::timevis(selected_session_data(), options = list(
      start = min(selected_session_data()$time),
      end = max(selected_session_data()$time)
    ))
  })
}
