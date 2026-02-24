cask "kanata-bar" do
  version "0.1.0"
  sha256 "TODO"  # update after first release: shasum -a 256 kanata-bar.app.zip

  url "https://github.com/not-in-stock/kanata-bar/releases/download/v#{version}/kanata-bar.app.zip"
  name "Kanata Bar"
  desc "macOS menu bar app for kanata keyboard remapper"
  homepage "https://github.com/not-in-stock/kanata-bar"

  app "kanata-bar.app"
end
