# src/apprt/core/translate.cr
module Apprt
  @@translator : String -> String = ->(text : String) { text }

  # Returns the function that translates apprt's built-in texts.
  def self.translator : String -> String
    @@translator
  end

  # Sets the function that translates apprt's built-in texts: labels,
  # tooltips, dialog texts and the titles of `Command.defaults` and
  # `Menu.window`. It receives the English text and returns the text to
  # show; the README lists every text apprt passes.
  #
  # Set it before creating the application; texts already shown keep their
  # language.
  #
  # ```
  # Apprt.translator = ->(text : String) { GERMAN[text]? || text }
  # ```
  def self.translator=(translator : String -> String) : String -> String
    @@translator = translator
  end

  # :nodoc:
  # Translates the built-in *text*, falling back to it when the translator
  # raises.
  def self.tr(text : String) : String
    @@translator.call(text)
  rescue ex
    Log.error(exception: ex) { "translator failed for #{text.inspect}" }
    text
  end
end
