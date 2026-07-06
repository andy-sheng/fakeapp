class Fakeapp < Formula
  desc "Build a debuggable Xcode project from a decrypted iOS IPA"
  homepage "https://github.com/andy-sheng/fakeapp"
  # `url`/`sha256` are maintained by scripts/brew-release.sh. Until the first
  # tagged release exists you can still install the tip of the default branch
  # with `brew install --HEAD`.
  url "https://github.com/andy-sheng/fakeapp/archive/refs/tags/v1.0.1.tar.gz"
  sha256 "201d6faa7c8923f1009d45fcdbd34d76af75a5768c53586d41b64abefeeab3f8"
  license "MIT"
  head "https://github.com/andy-sheng/fakeapp.git", branch: "master"

  depends_on :macos

  def install
    # Regenerate bin/fakeapp from fakeapp.sh + the fakesample/ template so the
    # embedded Xcode project always matches this exact source revision.
    system "bash", "./build.sh"
    bin.install "bin/fakeapp"
  end

  def caveats
    <<~EOS
      fakeapp drives Xcode's command-line tools at runtime (PlistBuddy, codesign,
      xcodebuild). Install the command line tools if you have not already:
        xcode-select --install
      Generating a runnable project also requires a full Xcode install.

      Only DECRYPTED IPA files are supported.
    EOS
  end

  test do
    assert_match "fakeapp - Create a debuggable Xcode project",
                 shell_output("#{bin}/fakeapp --help")
  end
end
