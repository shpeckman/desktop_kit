# src/apprt/core/icon.cr
module Apprt
  # An icon: the name of a themed icon (`String`, such as
  # `"utilities-terminal"`) or the path of an image file (`Path`).
  alias Icon = String | Path

  # :nodoc:
  # Builds the `GIcon` of an `Icon`; the caller owns the reference.
  module GIcon
    def self.new(icon : String) : Void*
      C.g_themed_icon_new(icon)
    end

    def self.new(icon : Path) : Void*
      file = C.g_file_new_for_path(icon.to_s)
      C.g_file_icon_new(file).tap { C.g_object_unref(file) }
    end

    # Returns a new `GtkImage` showing *icon*.
    def self.image(icon : Icon) : Void*
      gicon = new(icon)
      C.gtk_image_new_from_gicon(gicon).tap { C.g_object_unref(gicon) }
    end

    # Shows *icon* in *image*, or nothing for `nil`.
    def self.set(image : Widget, icon : Icon?) : Nil
      if icon
        gicon = new(icon)
        C.gtk_image_set_from_gicon(image, gicon)
        C.g_object_unref(gicon)
      else
        C.gtk_image_set_from_icon_name(image, nil)
      end
    end
  end
end
