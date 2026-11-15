# src/apprt/ui/progress.cr
module Apprt
  # Progress of a long task in a surface, shown on its pane, its tab and the
  # application's taskbar entry.
  struct Progress
    # How the task is going.
    enum State
      Normal
      Error
      Paused
    end

    # Returns the finished fraction from 0 to 1, or nil when it is unknown.
    getter value : Float64?

    getter state : State

    # Creates a progress at *value* (clamped to 0..1); nil shows an
    # indeterminate bar.
    def initialize(value : Float64? = nil, @state : State = :normal)
      @value = value.try(&.clamp(0.0, 1.0))
    end

    def indeterminate? : Bool
      @value.nil?
    end
  end

  # :nodoc:
  # The `com.canonical.Unity.LauncherEntry` signal taskbars read the
  # application's progress from.
  module LauncherEntry
    PATH      = "/com/canonical/unity/launcherentry/apprt"
    INTERFACE = "com.canonical.Unity.LauncherEntry"

    # Sends *progress*, or hides the entry's progress when nil, for the
    # desktop file named after *app_id*.
    def self.update(connection : Void*, app_id : String, progress : Float64?) : Nil
      return if connection.null?
      properties = {
        "progress"         => Variant.new(progress || 0.0),
        "progress-visible" => Variant.new(!progress.nil?),
      }
      parameters = Variant.new({"application://#{app_id}.desktop", properties})
      error = Pointer(C::GError).null
      C.g_dbus_connection_emit_signal(connection, nil, PATH, INTERFACE, "Update", parameters, pointerof(error))
      Log.warn { "launcher entry: #{GLibError.take(error).message}" } unless error.null?
    end
  end

  abstract class App
    @launcher_progress : Float64? = nil

    # Sends the mean of the surfaces' known progress to the taskbar, or
    # hides it when no surface has progress.
    protected def sync_progress : Nil
      values = @surfaces.each_value.compact_map(&.progress).map { |progress| progress.value || 0.0 }.to_a
      progress = values.empty? ? nil : values.sum / values.size
      return if progress == @launcher_progress
      @launcher_progress = progress
      return if @application.null?
      LauncherEntry.update(C.g_application_get_dbus_connection(@application), @id, progress)
    end
  end
end
