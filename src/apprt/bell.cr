# src/apprt/bell.cr
module Apprt
  # What `Surface#ring_bell` does.
  @[Flags]
  enum Bell
    # Beeps through the display server.
    System
    # Plays `App#bell_sound`.
    Audio
    # Marks the tab and the window as needing attention.
    Attention
    # Puts a bell before the tab title.
    Title
    # Draws a border around the surface.
    Border
  end

  abstract class App
    # What ringing a surface's bell does.
    property bell : Bell = Bell::System | Bell::Attention | Bell::Title

    # The sound file `Bell::Audio` plays.
    property bell_sound : Path? = nil

    # The volume of `#bell_sound`, from 0 to 1.
    getter bell_volume : Float64 = 0.5

    @bell_media = Pointer(Void).null
    @bell_media_path : Path? = nil

    # Sets the volume of `#bell_sound`, clamped to 0..1.
    def bell_volume=(volume : Float64) : Float64
      @bell_volume = volume.clamp(0.0, 1.0)
    end

    # Plays `#bell_sound` from the start; does nothing without one.
    protected def play_bell_sound : Nil
      path = @bell_sound || return
      unless @bell_media_path == path
        release_bell_sound
        media = C.gtk_media_file_new_for_filename(path.to_s)
        Signals.notify(media, "error", -> { bell_sound_failed(media, path) })
        bell_sound_failed(media, path)
        @bell_media = media
        @bell_media_path = path
      end
      C.gtk_media_stream_set_volume(@bell_media, @bell_volume)
      C.gtk_media_stream_seek(@bell_media, 0)
      C.gtk_media_stream_play(@bell_media)
    end

    private def release_bell_sound : Nil
      C.g_object_unref(@bell_media) unless @bell_media.null?
      @bell_media = Pointer(Void).null
      @bell_media_path = nil
    end

    private def bell_sound_failed(media : Void*, path : Path) : Nil
      error = C.gtk_media_stream_get_error(media)
      return if error.null?
      Log.warn { "bell sound #{path}: #{Native.string?(error.value.message)}" }
    end
  end
end
