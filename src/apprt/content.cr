# src/apprt/content.cr
module Apprt
  # What a surface shows; `App#new_surface` returns one for each new surface.
  #
  # A content belongs to one surface for its whole life.
  abstract class Content
    # Returns the surface showing the content; raises `NilAssertionError`
    # until `App#new_surface` has returned it.
    getter! surface : Surface

    protected setter surface : Surface?

    # :nodoc:
    # The widget the surface shows. GTK takes over its floating reference.
    abstract def widget : Widget

    # :showdoc:
    #
    # Called on `App#reload`, after `App#on_reload`, so the content can apply
    # the new configuration.
    protected def on_reload : Nil
    end

    # Calls `#on_reload` with an implicit receiver, which reaches overrides
    # defined outside `Apprt`.
    protected def reload : Nil
      on_reload
    end
  end

  # Content showing a GTK widget.
  class WidgetContent < Content
    # :nodoc:
    getter widget : Widget

    # Creates the content of *widget*, a new widget whose floating reference
    # the surface takes over.
    def initialize(@widget : Widget)
    end
  end

  # Describes a surface about to open; `App#new_surface` receives it.
  struct SurfaceContext
    # What the new surface opens as.
    enum Kind
      # The first surface of a new window.
      Window
      # The first surface of a new tab.
      Tab
      # A split beside an existing surface.
      Split
    end

    getter kind : Kind

    # Returns the surface the new one opens from: the one split, or the
    # focused one when a window or tab opens; `nil` when there is none.
    getter parent : Surface?

    # :nodoc:
    def initialize(@kind : Kind, @parent : Surface?)
    end
  end
end
