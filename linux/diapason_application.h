#pragma once

#include <gtk/gtk.h>

G_DECLARE_FINAL_TYPE(DiapasonApplication, diapason_application, DIAPASON, APPLICATION,
                     GtkApplication)

/**
 * diapason_application_new:
 *
 * Creates a new Flutter-based application for Diapason.
 *
 * Returns: a new #DiapasonApplication.
 */
DiapasonApplication* diapason_application_new();
