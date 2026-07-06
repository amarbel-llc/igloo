# Parse go.mod and go.work in Nix
# Returns Nix structures with the contents in normalised form.

let
  inherit (builtins)
    attrNames
    elemAt
    mapAttrs
    split
    foldl'
    match
    filter
    typeOf
    hasAttr
    length
    readFile
    ;

  # Strip lines with comments & other junk
  stripStr = s: elemAt (split "^ *" (elemAt (split " *$" s) 0)) 2;
  stripLines =
    initialLines:
    foldl' (acc: f: f acc) initialLines [
      # Strip comments
      (lines: map (l: stripStr (elemAt (splitString "//" l) 0)) lines)

      # Strip leading tabs characters
      (lines: map (l: elemAt (match "(\t)?(.*)" l) 1) lines)

      # Filter empty lines
      (filter (l: l != ""))
    ];

  # Parse lines into a structure
  parseLines =
    defaults: lines:
    (foldl'
      (
        acc: l:
        let
          m = match "([^ )]*) *(.*)" l; # Match the current line
          directive = elemAt m 0; # The directive (replace, require & so on)
          rest = elemAt m 1; # The rest of the current line

          # Maintain parser state (inside parens or not)
          inDirective =
            if rest == "(" then
              directive
            else if rest == ")" then
              null
            else
              acc.inDirective;

        in
        {
          data = (
            acc.data
            // (
              # If a we're in a directive and it's closing, no-op
              if directive == "" && rest == ")" then
                { }

              # If a directive is opening create the directive attrset
              else if inDirective != null && rest == "(" && !hasAttr inDirective acc.data then
                {
                  ${inDirective} = { };
                }

              # If we're closing any paren, no-op
              else if rest == "(" || rest == ")" then
                { }

              # If we're in a directive that has rest data assign it to the directive in the output
              else if inDirective != null then
                {
                  ${inDirective} = acc.data.${inDirective} // {
                    ${directive} = rest;
                  };
                }

              # Replace directive has unique structure and needs special casing
              else if directive == "replace" then
                (
                  let
                    # Split `foo => bar` into segments
                    segments = split " => " rest;
                    getSegment = elemAt segments;
                    # The LHS may carry a version restriction
                    # (`replace mod v1.0.0 => target`): key on the bare
                    # module path and keep the version in the value,
                    # matching the block-entry value shape that
                    # parseReplace normalises. See amarbel-llc/igloo#51.
                    lhsMatch = match "([^ ]+) +(.+)" (getSegment 0);
                    key = if lhsMatch == null then getSegment 0 else elemAt lhsMatch 0;
                    lhsPrefix = if lhsMatch == null then "" else "${elemAt lhsMatch 1} ";
                  in
                  assert length segments == 3;
                  {
                    # Assert well formed
                    replace = acc.data.replace // {
                      ${key} = "${lhsPrefix}=> ${getSegment 2}";
                    };
                  }
                )

              # Single-line entries of block-capable directives accumulate
              # into the directive's set instead of clobbering it with a
              # raw string, using the same line-split as block entries
              # (first token = key, remainder = value — empty for
              # bare-token directives like use/tool/retract). Valid go
              # files mix the two forms freely (`go mod tidy` emits
              # standalone indirect requires beside the grouped block;
              # `go work init` emits a single-line use), so parsing must
              # be order-independent. `replace` keeps its dedicated
              # ` => ` branch above; scalar directives (module, go,
              # toolchain) keep the default string assignment below.
              # See amarbel-llc/igloo#48 (require/exclude) and #50
              # (use/tool/retract).
              else if
                builtins.elem directive [
                  "require"
                  "exclude"
                  "tool"
                  "retract"
                  "use"
                ]
              then
                (
                  let
                    m2 = match "([^ ]+) *(.*)" rest;
                  in
                  assert m2 != null;
                  {
                    ${directive} = (acc.data.${directive} or { }) // {
                      ${elemAt m2 0} = elemAt m2 1;
                    };
                  }
                )

              # The default operation is to just assign the value
              else
                {
                  ${directive} = rest;
                }
            )
          );
          inherit inDirective;
        }
      )
      {
        # Default foldl' state
        inDirective = null;
        # The actual return data we're interested in (default empty structure)
        data = defaults;
      }
      lines
    ).data;

  # Normalise directives no matter what syntax produced them
  # meaning that:
  # replace github.com/nix-community/trustix/packages/go-lib => ../go-lib
  #
  # and:
  # replace (
  #     github.com/nix-community/trustix/packages/go-lib => ../go-lib
  # )
  #
  # gets the same structural representation.
  #
  # Addtionally this will create directives that are entirely missing from go.mod
  # as an empty attrset so it's output is more consistent.
  normaliseDirectives =
    data:
    (
      let
        normaliseString =
          s:
          let
            m = builtins.match "([^ ]+) (.+)" s;
          in
          {
            ${elemAt m 0} = elemAt m 1;
          };
        require = data.require or { };
        replace = data.replace or { };
        exclude = data.exclude or { };
      in
      data
      // {
        require = if typeOf require == "string" then normaliseString require else require;
        replace = if typeOf replace == "string" then normaliseString replace else replace;
        exclude = if typeOf exclude == "string" then normaliseString exclude else exclude;
      }
    );

  # Parse package paths & versions from replace directives
  parseReplace =
    data:
    (
      data
      // {
        replace = mapAttrs (
          _: v:
          let
            # An optional LHS version restriction precedes the arrow
            # (`replace mod v1.0.0 => target`): block entries arrive as
            # "v1.0.0 => target", unversioned ones as "=> target". See
            # amarbel-llc/igloo#51.
            mVer = match "([^ ]+) +=> +(.+)" v;
            lhsVersion = if mVer == null then null else elemAt mVer 0;
            target = if mVer == null then elemAt (match "=> +(.+)" v) 0 else elemAt mVer 1;
            m = match "([^ ]+) (.+)" target;
          in
          (
            if m != null then
              {
                goPackagePath = elemAt m 0;
                version = elemAt m 1;
              }
            else
              {
                path = target;
              }
          )
          // (if lhsVersion == null then { } else { inherit lhsVersion; })
        ) data.replace;
      }
    );

  splitString = sep: s: filter (t: t != [ ]) (split sep s);

  goModDefaults = {
    require = { };
    replace = { };
    exclude = { };
  };

  goWorkDefaults = {
    use = { };
    replace = { };
  };

  parseGoMod =
    contents:
    foldl' (acc: f: f acc) (splitString "\n" contents) [
      stripLines
      (parseLines goModDefaults)
      normaliseDirectives
      parseReplace
    ];

  # Parse go.work and return structure with:
  #   go: version string
  #   use: list of relative paths
  #   replace: attrset (same format as go.mod replace)
  parseGoWork =
    contents:
    let
      raw = foldl' (acc: f: f acc) (splitString "\n" contents) [
        stripLines
        (parseLines goWorkDefaults)
        normaliseDirectives
        parseReplace
      ];
    in
    raw
    // {
      # Convert use attrset { "./moduleA" = ""; } to list [ "./moduleA" ]
      use = attrNames (raw.use or { });
    };

in
{
  inherit parseGoMod parseGoWork;
}
