# spec/pure/portal_spec.cr
require "../spec_helper"

describe Apprt::Portal do
  it "predicts the request path from the unique name and the token" do
    Apprt::Portal.request_path(":1.42", "75af01a79c6fea34").should eq "/org/freedesktop/portal/desktop/request/1_42/75af01a79c6fea34"
  end

  it "makes distinct handle tokens that are valid object path elements" do
    tokens = Array.new(8) { Apprt::Portal.token }
    tokens.uniq.size.should eq 8
    tokens.each(&.should(match(/\Aapprt_[0-9a-f]{16}\z/)))
  end
end
