# src/apprt/window_style.cr
module Apprt
  # Look of the application's windows and the surfaces in them.
  #
  # ```
  # app.window_style = Apprt::WindowStyle.new(
  #   pane_headers: true, cards: true, tabs_in_header: true,
  #   opacity: 0.85, unfocused_opacity: 0.7)
  # ```
  struct WindowStyle
    # Whether each surface shows a header bar with its icon, its title and
    # buttons to split, zoom and close it.
    getter? pane_headers : Bool

    # Whether surfaces show as rounded cards with gaps between them.
    getter? cards : Bool

    # Whether the tab bar sits in the header bar, beside the window title,
    # instead of in a row below it.
    getter? tabs_in_header : Bool

    # Returns the opacity of the window background, from 0 to 1.
    getter opacity : Float64

    # Returns the opacity of the surfaces of a split other than the tab's
    # active one, from 0 to 1.
    getter unfocused_opacity : Float64

    # Creates a style; the defaults give GTK's plain look. Raises
    # `ArgumentError` when an opacity lies outside 0..1.
    def initialize(*, @pane_headers : Bool = false, @cards : Bool = false, @tabs_in_header : Bool = false,
                   @opacity : Float64 = 1.0, @unfocused_opacity : Float64 = 1.0)
      {opacity: @opacity, unfocused_opacity: @unfocused_opacity}.each do |name, value|
        raise ArgumentError.new("#{name} #{value} outside 0..1") unless 0.0 <= value <= 1.0
      end
    end

    # :nodoc:
    # The style sheet of the options, for windows with the `apprt-window`
    # class; empty for the defaults.
    def to_css : String
      String.build do |css|
        if @opacity < 1.0
          css << "window.apprt-window { background-color: alpha(@window_bg_color, #{@opacity}); }\n"
          css << "window.apprt-window headerbar, window.apprt-window tabbar .box, " \
                 "window.apprt-window toolbarview > .top-bar { background: none; box-shadow: none; }\n"
        end
        if @cards
          css << "window.apprt-window .surface { margin: 4px; border-radius: 12px; " \
                 "background-color: alpha(@view_bg_color, #{@opacity}); " \
                 "box-shadow: 0 0 0 1px alpha(@borders, 0.6); }\n"
          css << "window.apprt-window tabview { margin: 0 4px 4px 4px; }\n"
          css << "window.apprt-window paned > separator { background: none; box-shadow: none; }\n"
        end
        if @unfocused_opacity < 1.0
          css << "window.apprt-window .surface:not(.active) { opacity: #{@unfocused_opacity}; }\n"
        end
      end
    end
  end

  abstract class App
    @window_style = WindowStyle.new

    getter window_style : WindowStyle

    # Restyles the windows, the open ones included.
    def window_style=(style : WindowStyle) : WindowStyle
      @window_style = style
      UIThread.dispatch { apply_window_style } if running?
      style
    end

    private def apply_window_style : Nil
      load_runtime_style
      @windows.each(&.apply_style(@window_style))
      @surfaces.each_value(&.apply_style(@window_style))
    end

    # Loads the runtime's own style sheet and that of `#window_style`.
    private def load_runtime_style : Nil
      C.gtk_css_provider_load_from_string(@runtime_style, Surface::STYLE + Window::STYLE + @window_style.to_css)
    end
  end
end
