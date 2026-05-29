# Pin claude-code to 2.1.123 — earlier 2.1.x versions had TTY issues under
# the prior npm-based packaging. The new binary packaging may have resolved
# them; pin held while we verify.
final: prev:
let
  baseUrl = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases";
  pinnedVersion = "2.1.123";
  checksums = {
    "darwin-arm64" = "44597dff0f1c11e37c1954d4ac3965909be376e5961b558345723357253bcc90";
    "darwin-x64"   = "ddea227d4c2b2602d650d2c5d5c812f7680701a1504bcaff81e42c165c583ef9";
    "linux-arm64"  = "825c526035d1d75ff0bc1eebf18c887f98d07ea49ea80bd312ff416fe61a39b3";
    "linux-x64"    = "5a78139b679a86a88a0ac5476c706a64c3105bf6a6d435ba10f3aa3fb635bdb2";
  };
  platformKey = "${final.stdenv.hostPlatform.node.platform}-${final.stdenv.hostPlatform.node.arch}";
in
{
  claude-code = prev.claude-code.overrideAttrs (_: {
    version = pinnedVersion;
    src = final.fetchurl {
      url = "${baseUrl}/${pinnedVersion}/${platformKey}/claude";
      sha256 = checksums.${platformKey};
    };
  });
}
