# src/desktop_kit/ui/choosers.cr
module DesktopKit
  # A filter of the file dialogs: files matching any of *patterns* (globs
  # such as `"*.png"`) or *mime_types* (`"image/*"`), listed under *name*.
  record FileFilter, name : String, patterns : Array(String) = [] of String,
    mime_types : Array(String) = [] of String

  # A color with components from 0.0 to 1.0, as `Window#choose_color`
  # returns it.
  record Color, red : Float64, green : Float64, blue : Float64, alpha : Float64 = 1.0

  # What the about dialog (`Window#show_about`) tells of the application.
  #
  # *icon* is an icon name; *developers* lists names, optionally followed by
  # an email address in angle brackets or a URL.
  record About, name : String, version : String? = nil, icon : String? = nil,
    developer : String? = nil, developers : Array(String) = [] of String,
    comments : String? = nil, website : String? = nil, issue_url : String? = nil,
    copyright : String? = nil, license : About::License? = nil do
    # Licenses the about dialog names and links to.
    enum License
      Unknown
      Custom
      GPL20
      GPL30
      LGPL21
      LGPL30
      BSD
      MIT
      Artistic
      GPL20Only
      GPL30Only
      LGPL21Only
      LGPL30Only
      AGPL30
      AGPL30Only
      BSD3
      Apache20
      MPL20
      ZeroBSD
    end
  end

  # :nodoc:
  # GTK's file, color and font dialogs and libadwaita's about dialog.
  # Results come to a block on the GTK thread; dismissing a dialog yields
  # `nil` (an empty array when picking several files).
  module Choosers
    # Calls the `Proc(Void*, Void*, Nil)` *data* holds with the dialog and
    # the result.
    private FINISHED = ->(dialog : Void*, result : Void*, data : Void*) do
      block = Handles.get(data, Proc(Void*, Void*, Nil))
      Handles.release(data)
      begin
        block.call(dialog, result)
      rescue ex
        Log.error(exception: ex) { "dialog result" }
      end
      nil
    end

    # GTK_DIALOG_ERROR_FAILED; the other codes mean the user dismissed the
    # dialog.
    private FAILED = 0

    def self.open_file(parent : Widget, title : String, folder : Path?, filters : Enumerable(FileFilter), &done : Path? ->) : Nil
      dialog = file_dialog(title, folder, filters)
      C.gtk_file_dialog_open(dialog, parent, nil, FINISHED, finish { |source, result|
        done.call(take_path(finished { |error| C.gtk_file_dialog_open_finish(source, result, error) }))
      })
      C.g_object_unref(dialog)
    end

    def self.open_files(parent : Widget, title : String, folder : Path?, filters : Enumerable(FileFilter), &done : Array(Path) ->) : Nil
      dialog = file_dialog(title, folder, filters)
      C.gtk_file_dialog_open_multiple(dialog, parent, nil, FINISHED, finish { |source, result|
        done.call(take_paths(finished { |error| C.gtk_file_dialog_open_multiple_finish(source, result, error) }))
      })
      C.g_object_unref(dialog)
    end

    def self.save_file(parent : Widget, title : String, folder : Path?, name : String?, filters : Enumerable(FileFilter), &done : Path? ->) : Nil
      dialog = file_dialog(title, folder, filters)
      C.gtk_file_dialog_set_initial_name(dialog, name) if name
      C.gtk_file_dialog_save(dialog, parent, nil, FINISHED, finish { |source, result|
        done.call(take_path(finished { |error| C.gtk_file_dialog_save_finish(source, result, error) }))
      })
      C.g_object_unref(dialog)
    end

    def self.choose_folder(parent : Widget, title : String, folder : Path?, &done : Path? ->) : Nil
      dialog = file_dialog(title, folder, [] of FileFilter)
      C.gtk_file_dialog_select_folder(dialog, parent, nil, FINISHED, finish { |source, result|
        done.call(take_path(finished { |error| C.gtk_file_dialog_select_folder_finish(source, result, error) }))
      })
      C.g_object_unref(dialog)
    end

    def self.choose_color(parent : Widget, title : String, color : Color?, alpha : Bool, &done : Color? ->) : Nil
      dialog = C.gtk_color_dialog_new
      C.gtk_color_dialog_set_title(dialog, title)
      C.gtk_color_dialog_set_with_alpha(dialog, alpha ? 1 : 0)
      initial = color.try { |value| C::GdkRGBA.new(red: value.red.to_f32, green: value.green.to_f32, blue: value.blue.to_f32, alpha: value.alpha.to_f32) }
      C.gtk_color_dialog_choose_rgba(dialog, parent, initial ? pointerof(initial) : Pointer(C::GdkRGBA).null, nil, FINISHED, finish { |source, result|
        rgba = finished { |error| C.gtk_color_dialog_choose_rgba_finish(source, result, error).as(Void*) }.as(C::GdkRGBA*)
        if rgba.null?
          done.call(nil)
        else
          value = rgba.value
          C.gdk_rgba_free(rgba)
          done.call(Color.new(value.red.to_f64, value.green.to_f64, value.blue.to_f64, value.alpha.to_f64))
        end
      })
      C.g_object_unref(dialog)
    end

    def self.choose_font(parent : Widget, title : String, font : String?, &done : String? ->) : Nil
      dialog = C.gtk_font_dialog_new
      C.gtk_font_dialog_set_title(dialog, title)
      initial = font ? C.pango_font_description_from_string(font) : Pointer(Void).null
      C.gtk_font_dialog_choose_font(dialog, parent, initial, nil, FINISHED, finish { |source, result|
        description = finished { |error| C.gtk_font_dialog_choose_font_finish(source, result, error) }
        if description.null?
          done.call(nil)
        else
          name = Native.take_string?(C.pango_font_description_to_string(description))
          C.pango_font_description_free(description)
          done.call(name)
        end
      })
      C.pango_font_description_free(initial) unless initial.null?
      C.g_object_unref(dialog)
    end

    def self.about(parent : Widget, about : About) : Nil
      dialog = C.adw_about_dialog_new
      C.adw_about_dialog_set_application_name(dialog, about.name)
      about.version.try { |value| C.adw_about_dialog_set_version(dialog, value) }
      about.icon.try { |value| C.adw_about_dialog_set_application_icon(dialog, value) }
      about.developer.try { |value| C.adw_about_dialog_set_developer_name(dialog, value) }
      unless about.developers.empty?
        developers = Native.strv(about.developers)
        C.adw_about_dialog_set_developers(dialog, developers.to_unsafe)
      end
      about.comments.try { |value| C.adw_about_dialog_set_comments(dialog, value) }
      about.website.try { |value| C.adw_about_dialog_set_website(dialog, value) }
      about.issue_url.try { |value| C.adw_about_dialog_set_issue_url(dialog, value) }
      about.copyright.try { |value| C.adw_about_dialog_set_copyright(dialog, value) }
      about.license.try { |value| C.adw_about_dialog_set_license_type(dialog, C::GtkLicense.new(value.value)) }
      C.adw_dialog_present(dialog, parent)
    end

    private def self.file_dialog(title : String, folder : Path?, filters : Enumerable(FileFilter)) : Void*
      dialog = C.gtk_file_dialog_new
      C.gtk_file_dialog_set_title(dialog, title)
      if folder
        file = C.g_file_new_for_path(folder.to_s)
        C.gtk_file_dialog_set_initial_folder(dialog, file)
        C.g_object_unref(file)
      end
      unless filters.empty?
        store = C.g_list_store_new(C.gtk_file_filter_get_type)
        filters.each do |filter|
          native = C.gtk_file_filter_new
          C.gtk_file_filter_set_name(native, filter.name)
          filter.patterns.each { |pattern| C.gtk_file_filter_add_pattern(native, pattern) }
          filter.mime_types.each { |type| C.gtk_file_filter_add_mime_type(native, type) }
          C.g_list_store_append(store, native)
          C.g_object_unref(native)
        end
        C.gtk_file_dialog_set_filters(dialog, store)
        C.g_object_unref(store)
      end
      dialog
    end

    private def self.finish(&block : Void*, Void* -> Nil) : Void*
      Handles.retain(block)
    end

    # Returns what the block's finish call returned; logs a failure, and
    # returns null for it or a dismissal.
    private def self.finished(& : C::GError** -> Void*) : Void*
      error = Pointer(C::GError).null
      value = yield pointerof(error)
      return value if error.null?
      failure = GLibError.take(error)
      Log.warn { "dialog: #{failure.message}" } if failure.code == FAILED
      Pointer(Void).null
    end

    # Returns the local path of a `GFile` the callee allocated, and drops
    # it.
    private def self.take_path(file : Void*) : Path?
      return if file.null?
      Native.take_string?(C.g_file_get_path(file)).try { |path| Path[path] }
    ensure
      C.g_object_unref(file) unless file.null?
    end

    # Returns the local paths of a `GListModel` of `GFile`s the callee
    # allocated, and drops it.
    private def self.take_paths(files : Void*) : Array(Path)
      return [] of Path if files.null?
      Array.new(C.g_list_model_get_n_items(files).to_i32) { |index| take_path(C.g_list_model_get_item(files, index.to_u32)) }.compact
    ensure
      C.g_object_unref(files) unless files.null?
    end
  end
end
