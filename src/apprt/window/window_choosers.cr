# src/apprt/window/window_choosers.cr
module Apprt
  class Window
    # Asks the user for a file to open, in a dialog over the window that
    # starts in *folder* and offers *filters*, and yields its path, or
    # `nil` when they cancel.
    #
    # Inside a sandbox the desktop portal shows the dialog.
    #
    # ```
    # window.open_file(filters: [Apprt::FileFilter.new("Text", mime_types: ["text/plain"])]) do |path|
    #   editor.load(path) if path
    # end
    # ```
    def open_file(*, title : String = Apprt.tr("Open File"), folder : Path? = nil,
                  filters : Enumerable(FileFilter) = [] of FileFilter, &block : Path? ->) : Nil
      return if @closed
      Choosers.open_file(@widget, title, folder, filters, &block)
    end

    # Asks the user for files to open, as `#open_file` does, and yields
    # their paths, none when they cancel.
    def open_files(*, title : String = Apprt.tr("Open Files"), folder : Path? = nil,
                   filters : Enumerable(FileFilter) = [] of FileFilter, &block : Array(Path) ->) : Nil
      return if @closed
      Choosers.open_files(@widget, title, folder, filters, &block)
    end

    # Asks the user where to save a file, suggesting *name* in *folder*,
    # and yields the path, or `nil` when they cancel.
    #
    # The dialog asks before replacing an existing file.
    def save_file(*, title : String = Apprt.tr("Save File"), folder : Path? = nil, name : String? = nil,
                  filters : Enumerable(FileFilter) = [] of FileFilter, &block : Path? ->) : Nil
      return if @closed
      Choosers.save_file(@widget, title, folder, name, filters, &block)
    end

    # Asks the user for a folder, starting in *folder*, and yields its path,
    # or `nil` when they cancel.
    def choose_folder(*, title : String = Apprt.tr("Select Folder"), folder : Path? = nil, &block : Path? ->) : Nil
      return if @closed
      Choosers.choose_folder(@widget, title, folder, &block)
    end

    # Asks the user for a color, starting from *color*, and yields it, or
    # `nil` when they cancel. With *alpha* they also pick an opacity.
    def choose_color(*, title : String = Apprt.tr("Select Color"), color : Color? = nil, alpha : Bool = true,
                     &block : Color? ->) : Nil
      return if @closed
      Choosers.choose_color(@widget, title, color, alpha, &block)
    end

    # Asks the user for a font, starting from *font*, and yields it, or
    # `nil` when they cancel. Fonts are descriptions such as
    # `"Monospace Bold 12"`: family, style options and size in points.
    def choose_font(*, title : String = Apprt.tr("Select Font"), font : String? = nil, &block : String? ->) : Nil
      return if @closed
      Choosers.choose_font(@widget, title, font, &block)
    end

    # Shows the about dialog of the application over the window.
    #
    # ```
    # window.show_about(Apprt::About.new("Editor", version: "1.0", license: :gpl30))
    # ```
    def show_about(about : About) : Nil
      return if @closed
      Choosers.about(@widget, about)
    end
  end
end
