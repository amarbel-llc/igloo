# Fetch a GGUF embedding model file (e.g. from HuggingFace).
#
# Accepts sha256 in any format builtins.convertHash supports: hex (base16),
# base32, base64, or SRI (sha256-<base64>). HuggingFace displays hex sha256
# on file pages, so callers can paste it directly without manual conversion.
#
# Example:
#
#   fetchGgufModel {
#     name = "snowflake-arctic-embed-l-v2.0-q8_0";
#     url = "https://huggingface.co/.../snowflake-arctic-embed-l-v2.0-q8_0.gguf";
#     sha256 = "09be832ec0b3...";  # hex from HuggingFace, or SRI sha256-...
#   }
#
{ fetchurl, lib }:
{
  name,
  url,
  sha256,
}:
fetchurl {
  inherit url;
  name = "${name}.gguf";
  hash = builtins.convertHash {
    hash = sha256;
    hashAlgo = "sha256";
    toHashFormat = "sri";
  };
}
