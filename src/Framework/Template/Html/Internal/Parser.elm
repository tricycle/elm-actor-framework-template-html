module Framework.Template.Html.Internal.Parser exposing
    ( node
    , nodeToString
    , parse
    )

import Dict exposing (Dict)
import Framework.Template exposing (ActorElement(..), Node(..))
import Framework.Template.Component as Component
import Framework.Template.Components as Components exposing (Components)
import Framework.Template.Html.Internal.HtmlTemplate as HtmlTemplate exposing (HtmlTemplate)
import Hex
import MD5
import Parser exposing ((|.), (|=), Parser)


parse : Components appActors -> String -> Result String (HtmlTemplate appActors)
parse components str =
    if String.isEmpty str then
        Ok HtmlTemplate.empty

    else
        Parser.run (oneOrMore "node" (node components)) str
            |> Result.map HtmlTemplate.fromNodes
            |> Result.mapError Parser.deadEndsToString


type alias Attribute =
    ( String, String )


node : Components appActors -> Parser (Maybe (Node appActors))
node components =
    Parser.oneOf
        [ text
        , comment
        , element components
        ]


nodeToString : Node appActors -> String
nodeToString node_ =
    case node_ of
        Text string ->
            string

        Element name attributes children ->
            elementToString name attributes children

        Actor (ActorElement _ name _ attributes children) ->
            elementToString name attributes children



-- Text


text : Parser (Maybe (Node appActors))
text =
    Parser.oneOf
        [ Parser.getChompedString
            (chompOneOrMore
                (\c ->
                    case c of
                        '<' ->
                            False

                        '&' ->
                            False

                        _ ->
                            True
                )
            )
        , characterReference
        ]
        |> Parser.map Just
        |> oneOrMore "text element"
        |> Parser.map
            (\rawStr ->
                case String.join "" rawStr |> String.trim of
                    "" ->
                        Nothing

                    str ->
                        Just <| Text str
            )


characterReference : Parser String
characterReference =
    Parser.succeed identity
        |. Parser.chompIf
            (\c ->
                case c of
                    '&' ->
                        True

                    _ ->
                        False
            )
        |= Parser.oneOf
            [ Parser.backtrackable namedCharacterReference
                |. chompSemicolon
            , Parser.backtrackable numericCharacterReference
                |. chompSemicolon
            , Parser.succeed "&"
            ]


namedCharacterReference : Parser String
namedCharacterReference =
    Parser.getChompedString (chompOneOrMore Char.isAlpha)
        |> Parser.map
            (\reference ->
                Dict.get reference namedCharacterReferenceDict
                    |> Maybe.withDefault ("&" ++ reference ++ ";")
            )


numericCharacterReference : Parser String
numericCharacterReference =
    let
        codepoint =
            Parser.oneOf
                [ Parser.succeed identity
                    |. Parser.chompIf
                        (\c ->
                            case c of
                                'x' ->
                                    True

                                'X' ->
                                    True

                                _ ->
                                    False
                        )
                    |= hexadecimal
                , Parser.succeed identity
                    |. Parser.chompWhile
                        (\c ->
                            case c of
                                '0' ->
                                    True

                                _ ->
                                    False
                        )
                    |= Parser.int
                ]
    in
    Parser.succeed identity
        |. Parser.chompIf
            (\c ->
                case c of
                    '#' ->
                        True

                    _ ->
                        False
            )
        |= Parser.map (Char.fromCode >> String.fromChar) codepoint



-- Element


elementOrActorElement : Components appActors -> String -> List Attribute -> List (Node appActors) -> Node appActors
elementOrActorElement components name attributes children =
    case Components.getByNodeName name components of
        Just component ->
            let
                actor =
                    Component.toActor component

                id =
                    nodeToString (Element name attributes children)
                        |> MD5.hex

                mergeAttributes a b =
                    Dict.union (Dict.fromList a) (Dict.fromList b)
                        |> Dict.toList

                mergedAttributes =
                    Component.toDefaultAttributes component
                        |> mergeAttributes attributes
            in
            Actor <| ActorElement actor name id mergedAttributes children

        Nothing ->
            Element name attributes children


element : Components appActors -> Parser (Maybe (Node appActors))
element components =
    Parser.succeed Tuple.pair
        |. Parser.chompIf
            (\c ->
                case c of
                    '<' ->
                        True

                    _ ->
                        False
            )
        |= tagName
        |. Parser.chompWhile isSpaceCharacter
        |= tagAttributes
        |> Parser.andThen
            (\( name, attributes ) ->
                if isSelfClosingElement name then
                    Parser.succeed (Just <| elementOrActorElement components name attributes [])
                        |. Parser.oneOf
                            [ Parser.chompIf
                                (\c ->
                                    case c of
                                        '/' ->
                                            True

                                        _ ->
                                            False
                                )
                            , Parser.succeed ()
                            ]
                        |. Parser.chompIf
                            (\c ->
                                case c of
                                    '>' ->
                                        True

                                    _ ->
                                        False
                            )

                else
                    Parser.succeed (Just << elementOrActorElement components name attributes)
                        |. Parser.chompIf
                            (\c ->
                                case c of
                                    '>' ->
                                        True

                                    _ ->
                                        False
                            )
                        |= many (Parser.backtrackable (node components))
                        |. closingTag name
            )


tagName : Parser String
tagName =
    Parser.getChompedString
        (Parser.chompIf Char.isAlphaNum
            |. Parser.chompWhile
                (\c ->
                    case c of
                        '-' ->
                            True

                        _ ->
                            Char.isAlphaNum c
                )
        )
        |> Parser.map String.toLower


tagAttributes : Parser (List Attribute)
tagAttributes =
    many (Parser.map Just tagAttribute)


tagAttribute : Parser Attribute
tagAttribute =
    Parser.succeed Tuple.pair
        |= tagAttributeName
        |. Parser.chompWhile isSpaceCharacter
        |= tagAttributeValue
        |. Parser.chompWhile isSpaceCharacter


tagAttributeName : Parser String
tagAttributeName =
    Parser.getChompedString (chompOneOrMore isTagAttributeCharacter)
        |> Parser.map String.toLower


tagAttributeValue : Parser String
tagAttributeValue =
    Parser.oneOf
        [ Parser.succeed identity
            |. Parser.chompIf
                (\c ->
                    case c of
                        '=' ->
                            True

                        _ ->
                            False
                )
            |. Parser.chompWhile isSpaceCharacter
            |= Parser.oneOf
                [ tagAttributeUnquotedValue
                , tagAttributeQuotedValue '"'
                , tagAttributeQuotedValue '\''
                ]
        , Parser.succeed ""
        ]


tagAttributeUnquotedValue : Parser String
tagAttributeUnquotedValue =
    let
        isUnquotedValueChar c =
            case c of
                '"' ->
                    False

                '\'' ->
                    False

                '=' ->
                    False

                '<' ->
                    False

                '>' ->
                    False

                '`' ->
                    False

                '&' ->
                    False

                _ ->
                    not <| isSpaceCharacter c
    in
    Parser.oneOf
        [ chompOneOrMore isUnquotedValueChar
            |> Parser.getChompedString
        , characterReference
        ]
        |> Parser.map Just
        |> oneOrMore "attribute value"
        |> Parser.map (String.join "")


tagAttributeQuotedValue : Char -> Parser String
tagAttributeQuotedValue quote =
    let
        isQuotedValueChar c =
            case c of
                '&' ->
                    False

                _ ->
                    c /= quote
    in
    Parser.succeed identity
        |. Parser.chompIf ((==) quote)
        |= (Parser.oneOf
                [ Parser.getChompedString (chompOneOrMore isQuotedValueChar)
                , characterReference
                ]
                |> Parser.map Just
                |> many
                |> Parser.map (String.join "")
           )
        |. Parser.chompIf ((==) quote)


closingTag : String -> Parser ()
closingTag name =
    let
        chompName =
            chompOneOrMore
                (\c ->
                    case c of
                        '>' ->
                            False

                        _ ->
                            not <| isSpaceCharacter c
                )
                |> Parser.getChompedString
                |> Parser.andThen
                    (\closingName ->
                        if String.toLower closingName == name then
                            Parser.succeed ()

                        else
                            Parser.problem ("closing tag does not match opening tag: " ++ name)
                    )
    in
    Parser.chompIf
        (\c ->
            case c of
                '<' ->
                    True

                _ ->
                    False
        )
        |. Parser.chompIf
            (\c ->
                case c of
                    '/' ->
                        True

                    _ ->
                        False
            )
        |. chompName
        |. Parser.chompWhile isSpaceCharacter
        |. Parser.chompIf
            (\c ->
                case c of
                    '>' ->
                        True

                    _ ->
                        False
            )


elementToString : String -> List Attribute -> List (Node appActors) -> String
elementToString name attributes children =
    let
        attributeToString ( attr, value ) =
            attr ++ "=\"" ++ value ++ "\""

        maybeAttributes =
            case attributes of
                [] ->
                    ""

                _ ->
                    " " ++ String.join " " (List.map attributeToString attributes)
    in
    if isSelfClosingElement name then
        String.concat
            [ "<"
            , name
            , maybeAttributes
            , ">"
            ]

    else
        String.concat
            [ "<"
            , name
            , maybeAttributes
            , ">"
            , String.join "" (List.map nodeToString children)
            , "</"
            , name
            , ">"
            ]



-- Comment


comment : Parser (Maybe a)
comment =
    Parser.map (always Nothing) commentString


commentString : Parser String
commentString =
    Parser.succeed Basics.identity
        |. Parser.token "<!"
        |. Parser.token "--"
        |= Parser.getChompedString (Parser.chompUntil "-->")
        |. Parser.token "-->"


isSelfClosingElement : String -> Bool
isSelfClosingElement name =
    case name of
        "img" ->
            True

        "br" ->
            True

        "hr" ->
            True

        "input" ->
            True

        "link" ->
            True

        "meta" ->
            True

        _ ->
            False



-- Character validators


isTagAttributeCharacter : Char -> Bool
isTagAttributeCharacter c =
    case c of
        '"' ->
            False

        '\'' ->
            False

        '>' ->
            False

        '/' ->
            False

        '=' ->
            False

        _ ->
            not <| isSpaceCharacter c


isSpaceCharacter : Char -> Bool
isSpaceCharacter c =
    case c of
        ' ' ->
            True

        '\t' ->
            True

        '\n' ->
            True

        _ ->
            False



-- Chomp


chompSemicolon : Parser ()
chompSemicolon =
    Parser.chompIf
        (\c ->
            case c of
                ';' ->
                    True

                _ ->
                    False
        )


chompOneOrMore : (Char -> Bool) -> Parser ()
chompOneOrMore fn =
    Parser.chompIf fn
        |. Parser.chompWhile fn



-- Types


hexadecimal : Parser Int
hexadecimal =
    chompOneOrMore Char.isHexDigit
        |> Parser.getChompedString
        |> Parser.andThen
            (\hex ->
                case Hex.fromString (String.toLower hex) of
                    Ok value ->
                        Parser.succeed value

                    Err error ->
                        Parser.problem error
            )



-- Loops


many : Parser (Maybe a) -> Parser (List a)
many parser_ =
    Parser.loop []
        (\list ->
            Parser.oneOf
                [ parser_ |> Parser.map (\new -> Parser.Loop (new :: list))
                , Parser.succeed (Parser.Done (List.reverse list |> List.filterMap identity))
                ]
        )


oneOrMore : String -> Parser (Maybe a) -> Parser (List a)
oneOrMore type_ parser_ =
    Parser.loop []
        (\list ->
            Parser.oneOf
                [ parser_ |> Parser.map (\new -> Parser.Loop (new :: list))
                , if List.isEmpty list then
                    Parser.problem ("expecting at least one " ++ type_)

                  else
                    Parser.succeed (Parser.Done (List.reverse list |> List.filterMap identity))
                ]
        )



---


namedCharacterReferenceDict : Dict String String
namedCharacterReferenceDict =
    -- Source: https://www.w3.org/TR/html5/syntax.html#named-character-references
    [ ( "Aacute", "Á" )
    , ( "aacute", "á" )
    , ( "Abreve", "Ă" )
    , ( "abreve", "ă" )
    , ( "ac", "∾" )
    , ( "acd", "∿" )
    , ( "acE", "∾̳" )
    , ( "Acirc", "Â" )
    , ( "acirc", "â" )
    , ( "acute", "´" )
    , ( "Acy", "А" )
    , ( "acy", "а" )
    , ( "AElig", "Æ" )
    , ( "aelig", "æ" )
    , ( "af", "\u{2061}" )
    , ( "Afr", "\u{D835}\u{DD04}" )
    , ( "afr", "\u{D835}\u{DD1E}" )
    , ( "Agrave", "À" )
    , ( "agrave", "à" )
    , ( "alefsym", "ℵ" )
    , ( "aleph", "ℵ" )
    , ( "Alpha", "Α" )
    , ( "alpha", "α" )
    , ( "Amacr", "Ā" )
    , ( "amacr", "ā" )
    , ( "amalg", "⨿" )
    , ( "amp", "&" )
    , ( "AMP", "&" )
    , ( "andand", "⩕" )
    , ( "And", "⩓" )
    , ( "and", "∧" )
    , ( "andd", "⩜" )
    , ( "andslope", "⩘" )
    , ( "andv", "⩚" )
    , ( "ang", "∠" )
    , ( "ange", "⦤" )
    , ( "angle", "∠" )
    , ( "angmsdaa", "⦨" )
    , ( "angmsdab", "⦩" )
    , ( "angmsdac", "⦪" )
    , ( "angmsdad", "⦫" )
    , ( "angmsdae", "⦬" )
    , ( "angmsdaf", "⦭" )
    , ( "angmsdag", "⦮" )
    , ( "angmsdah", "⦯" )
    , ( "angmsd", "∡" )
    , ( "angrt", "∟" )
    , ( "angrtvb", "⊾" )
    , ( "angrtvbd", "⦝" )
    , ( "angsph", "∢" )
    , ( "angst", "Å" )
    , ( "angzarr", "⍼" )
    , ( "Aogon", "Ą" )
    , ( "aogon", "ą" )
    , ( "Aopf", "\u{D835}\u{DD38}" )
    , ( "aopf", "\u{D835}\u{DD52}" )
    , ( "apacir", "⩯" )
    , ( "ap", "≈" )
    , ( "apE", "⩰" )
    , ( "ape", "≊" )
    , ( "apid", "≋" )
    , ( "apos", "'" )
    , ( "ApplyFunction", "\u{2061}" )
    , ( "approx", "≈" )
    , ( "approxeq", "≊" )
    , ( "Aring", "Å" )
    , ( "aring", "å" )
    , ( "Ascr", "\u{D835}\u{DC9C}" )
    , ( "ascr", "\u{D835}\u{DCB6}" )
    , ( "Assign", "≔" )
    , ( "ast", "*" )
    , ( "asymp", "≈" )
    , ( "asympeq", "≍" )
    , ( "Atilde", "Ã" )
    , ( "atilde", "ã" )
    , ( "Auml", "Ä" )
    , ( "auml", "ä" )
    , ( "awconint", "∳" )
    , ( "awint", "⨑" )
    , ( "backcong", "≌" )
    , ( "backepsilon", "϶" )
    , ( "backprime", "‵" )
    , ( "backsim", "∽" )
    , ( "backsimeq", "⋍" )
    , ( "Backslash", "∖" )
    , ( "Barv", "⫧" )
    , ( "barvee", "⊽" )
    , ( "barwed", "⌅" )
    , ( "Barwed", "⌆" )
    , ( "barwedge", "⌅" )
    , ( "bbrk", "⎵" )
    , ( "bbrktbrk", "⎶" )
    , ( "bcong", "≌" )
    , ( "Bcy", "Б" )
    , ( "bcy", "б" )
    , ( "bdquo", "„" )
    , ( "becaus", "∵" )
    , ( "because", "∵" )
    , ( "Because", "∵" )
    , ( "bemptyv", "⦰" )
    , ( "bepsi", "϶" )
    , ( "bernou", "ℬ" )
    , ( "Bernoullis", "ℬ" )
    , ( "Beta", "Β" )
    , ( "beta", "β" )
    , ( "beth", "ℶ" )
    , ( "between", "≬" )
    , ( "Bfr", "\u{D835}\u{DD05}" )
    , ( "bfr", "\u{D835}\u{DD1F}" )
    , ( "bigcap", "⋂" )
    , ( "bigcirc", "◯" )
    , ( "bigcup", "⋃" )
    , ( "bigodot", "⨀" )
    , ( "bigoplus", "⨁" )
    , ( "bigotimes", "⨂" )
    , ( "bigsqcup", "⨆" )
    , ( "bigstar", "★" )
    , ( "bigtriangledown", "▽" )
    , ( "bigtriangleup", "△" )
    , ( "biguplus", "⨄" )
    , ( "bigvee", "⋁" )
    , ( "bigwedge", "⋀" )
    , ( "bkarow", "⤍" )
    , ( "blacklozenge", "⧫" )
    , ( "blacksquare", "▪" )
    , ( "blacktriangle", "▴" )
    , ( "blacktriangledown", "▾" )
    , ( "blacktriangleleft", "◂" )
    , ( "blacktriangleright", "▸" )
    , ( "blank", "␣" )
    , ( "blk12", "▒" )
    , ( "blk14", "░" )
    , ( "blk34", "▓" )
    , ( "block", "█" )
    , ( "bne", "=⃥" )
    , ( "bnequiv", "≡⃥" )
    , ( "bNot", "⫭" )
    , ( "bnot", "⌐" )
    , ( "Bopf", "\u{D835}\u{DD39}" )
    , ( "bopf", "\u{D835}\u{DD53}" )
    , ( "bot", "⊥" )
    , ( "bottom", "⊥" )
    , ( "bowtie", "⋈" )
    , ( "boxbox", "⧉" )
    , ( "boxdl", "┐" )
    , ( "boxdL", "╕" )
    , ( "boxDl", "╖" )
    , ( "boxDL", "╗" )
    , ( "boxdr", "┌" )
    , ( "boxdR", "╒" )
    , ( "boxDr", "╓" )
    , ( "boxDR", "╔" )
    , ( "boxh", "─" )
    , ( "boxH", "═" )
    , ( "boxhd", "┬" )
    , ( "boxHd", "╤" )
    , ( "boxhD", "╥" )
    , ( "boxHD", "╦" )
    , ( "boxhu", "┴" )
    , ( "boxHu", "╧" )
    , ( "boxhU", "╨" )
    , ( "boxHU", "╩" )
    , ( "boxminus", "⊟" )
    , ( "boxplus", "⊞" )
    , ( "boxtimes", "⊠" )
    , ( "boxul", "┘" )
    , ( "boxuL", "╛" )
    , ( "boxUl", "╜" )
    , ( "boxUL", "╝" )
    , ( "boxur", "└" )
    , ( "boxuR", "╘" )
    , ( "boxUr", "╙" )
    , ( "boxUR", "╚" )
    , ( "boxv", "│" )
    , ( "boxV", "║" )
    , ( "boxvh", "┼" )
    , ( "boxvH", "╪" )
    , ( "boxVh", "╫" )
    , ( "boxVH", "╬" )
    , ( "boxvl", "┤" )
    , ( "boxvL", "╡" )
    , ( "boxVl", "╢" )
    , ( "boxVL", "╣" )
    , ( "boxvr", "├" )
    , ( "boxvR", "╞" )
    , ( "boxVr", "╟" )
    , ( "boxVR", "╠" )
    , ( "bprime", "‵" )
    , ( "breve", "˘" )
    , ( "Breve", "˘" )
    , ( "brvbar", "¦" )
    , ( "bscr", "\u{D835}\u{DCB7}" )
    , ( "Bscr", "ℬ" )
    , ( "bsemi", "⁏" )
    , ( "bsim", "∽" )
    , ( "bsime", "⋍" )
    , ( "bsolb", "⧅" )
    , ( "bsol", "\\" )
    , ( "bsolhsub", "⟈" )
    , ( "bull", "•" )
    , ( "bullet", "•" )
    , ( "bump", "≎" )
    , ( "bumpE", "⪮" )
    , ( "bumpe", "≏" )
    , ( "Bumpeq", "≎" )
    , ( "bumpeq", "≏" )
    , ( "Cacute", "Ć" )
    , ( "cacute", "ć" )
    , ( "capand", "⩄" )
    , ( "capbrcup", "⩉" )
    , ( "capcap", "⩋" )
    , ( "cap", "∩" )
    , ( "Cap", "⋒" )
    , ( "capcup", "⩇" )
    , ( "capdot", "⩀" )
    , ( "CapitalDifferentialD", "ⅅ" )
    , ( "caps", "∩︀" )
    , ( "caret", "⁁" )
    , ( "caron", "ˇ" )
    , ( "Cayleys", "ℭ" )
    , ( "ccaps", "⩍" )
    , ( "Ccaron", "Č" )
    , ( "ccaron", "č" )
    , ( "Ccedil", "Ç" )
    , ( "ccedil", "ç" )
    , ( "Ccirc", "Ĉ" )
    , ( "ccirc", "ĉ" )
    , ( "Cconint", "∰" )
    , ( "ccups", "⩌" )
    , ( "ccupssm", "⩐" )
    , ( "Cdot", "Ċ" )
    , ( "cdot", "ċ" )
    , ( "cedil", "¸" )
    , ( "Cedilla", "¸" )
    , ( "cemptyv", "⦲" )
    , ( "cent", "¢" )
    , ( "centerdot", "·" )
    , ( "CenterDot", "·" )
    , ( "cfr", "\u{D835}\u{DD20}" )
    , ( "Cfr", "ℭ" )
    , ( "CHcy", "Ч" )
    , ( "chcy", "ч" )
    , ( "check", "✓" )
    , ( "checkmark", "✓" )
    , ( "Chi", "Χ" )
    , ( "chi", "χ" )
    , ( "circ", "ˆ" )
    , ( "circeq", "≗" )
    , ( "circlearrowleft", "↺" )
    , ( "circlearrowright", "↻" )
    , ( "circledast", "⊛" )
    , ( "circledcirc", "⊚" )
    , ( "circleddash", "⊝" )
    , ( "CircleDot", "⊙" )
    , ( "circledR", "®" )
    , ( "circledS", "Ⓢ" )
    , ( "CircleMinus", "⊖" )
    , ( "CirclePlus", "⊕" )
    , ( "CircleTimes", "⊗" )
    , ( "cir", "○" )
    , ( "cirE", "⧃" )
    , ( "cire", "≗" )
    , ( "cirfnint", "⨐" )
    , ( "cirmid", "⫯" )
    , ( "cirscir", "⧂" )
    , ( "ClockwiseContourIntegral", "∲" )
    , ( "CloseCurlyDoubleQuote", "”" )
    , ( "CloseCurlyQuote", "’" )
    , ( "clubs", "♣" )
    , ( "clubsuit", "♣" )
    , ( "colon", ":" )
    , ( "Colon", "∷" )
    , ( "Colone", "⩴" )
    , ( "colone", "≔" )
    , ( "coloneq", "≔" )
    , ( "comma", "," )
    , ( "commat", "@" )
    , ( "comp", "∁" )
    , ( "compfn", "∘" )
    , ( "complement", "∁" )
    , ( "complexes", "ℂ" )
    , ( "cong", "≅" )
    , ( "congdot", "⩭" )
    , ( "Congruent", "≡" )
    , ( "conint", "∮" )
    , ( "Conint", "∯" )
    , ( "ContourIntegral", "∮" )
    , ( "copf", "\u{D835}\u{DD54}" )
    , ( "Copf", "ℂ" )
    , ( "coprod", "∐" )
    , ( "Coproduct", "∐" )
    , ( "copy", "©" )
    , ( "COPY", "©" )
    , ( "copysr", "℗" )
    , ( "CounterClockwiseContourIntegral", "∳" )
    , ( "crarr", "↵" )
    , ( "cross", "✗" )
    , ( "Cross", "⨯" )
    , ( "Cscr", "\u{D835}\u{DC9E}" )
    , ( "cscr", "\u{D835}\u{DCB8}" )
    , ( "csub", "⫏" )
    , ( "csube", "⫑" )
    , ( "csup", "⫐" )
    , ( "csupe", "⫒" )
    , ( "ctdot", "⋯" )
    , ( "cudarrl", "⤸" )
    , ( "cudarrr", "⤵" )
    , ( "cuepr", "⋞" )
    , ( "cuesc", "⋟" )
    , ( "cularr", "↶" )
    , ( "cularrp", "⤽" )
    , ( "cupbrcap", "⩈" )
    , ( "cupcap", "⩆" )
    , ( "CupCap", "≍" )
    , ( "cup", "∪" )
    , ( "Cup", "⋓" )
    , ( "cupcup", "⩊" )
    , ( "cupdot", "⊍" )
    , ( "cupor", "⩅" )
    , ( "cups", "∪︀" )
    , ( "curarr", "↷" )
    , ( "curarrm", "⤼" )
    , ( "curlyeqprec", "⋞" )
    , ( "curlyeqsucc", "⋟" )
    , ( "curlyvee", "⋎" )
    , ( "curlywedge", "⋏" )
    , ( "curren", "¤" )
    , ( "curvearrowleft", "↶" )
    , ( "curvearrowright", "↷" )
    , ( "cuvee", "⋎" )
    , ( "cuwed", "⋏" )
    , ( "cwconint", "∲" )
    , ( "cwint", "∱" )
    , ( "cylcty", "⌭" )
    , ( "dagger", "†" )
    , ( "Dagger", "‡" )
    , ( "daleth", "ℸ" )
    , ( "darr", "↓" )
    , ( "Darr", "↡" )
    , ( "dArr", "⇓" )
    , ( "dash", "‐" )
    , ( "Dashv", "⫤" )
    , ( "dashv", "⊣" )
    , ( "dbkarow", "⤏" )
    , ( "dblac", "˝" )
    , ( "Dcaron", "Ď" )
    , ( "dcaron", "ď" )
    , ( "Dcy", "Д" )
    , ( "dcy", "д" )
    , ( "ddagger", "‡" )
    , ( "ddarr", "⇊" )
    , ( "DD", "ⅅ" )
    , ( "dd", "ⅆ" )
    , ( "DDotrahd", "⤑" )
    , ( "ddotseq", "⩷" )
    , ( "deg", "°" )
    , ( "Del", "∇" )
    , ( "Delta", "Δ" )
    , ( "delta", "δ" )
    , ( "demptyv", "⦱" )
    , ( "dfisht", "⥿" )
    , ( "Dfr", "\u{D835}\u{DD07}" )
    , ( "dfr", "\u{D835}\u{DD21}" )
    , ( "dHar", "⥥" )
    , ( "dharl", "⇃" )
    , ( "dharr", "⇂" )
    , ( "DiacriticalAcute", "´" )
    , ( "DiacriticalDot", "˙" )
    , ( "DiacriticalDoubleAcute", "˝" )
    , ( "DiacriticalGrave", "`" )
    , ( "DiacriticalTilde", "˜" )
    , ( "diam", "⋄" )
    , ( "diamond", "⋄" )
    , ( "Diamond", "⋄" )
    , ( "diamondsuit", "♦" )
    , ( "diams", "♦" )
    , ( "die", "¨" )
    , ( "DifferentialD", "ⅆ" )
    , ( "digamma", "ϝ" )
    , ( "disin", "⋲" )
    , ( "div", "÷" )
    , ( "divide", "÷" )
    , ( "divideontimes", "⋇" )
    , ( "divonx", "⋇" )
    , ( "DJcy", "Ђ" )
    , ( "djcy", "ђ" )
    , ( "dlcorn", "⌞" )
    , ( "dlcrop", "⌍" )
    , ( "dollar", "$" )
    , ( "Dopf", "\u{D835}\u{DD3B}" )
    , ( "dopf", "\u{D835}\u{DD55}" )
    , ( "Dot", "¨" )
    , ( "dot", "˙" )
    , ( "DotDot", "⃜" )
    , ( "doteq", "≐" )
    , ( "doteqdot", "≑" )
    , ( "DotEqual", "≐" )
    , ( "dotminus", "∸" )
    , ( "dotplus", "∔" )
    , ( "dotsquare", "⊡" )
    , ( "doublebarwedge", "⌆" )
    , ( "DoubleContourIntegral", "∯" )
    , ( "DoubleDot", "¨" )
    , ( "DoubleDownArrow", "⇓" )
    , ( "DoubleLeftArrow", "⇐" )
    , ( "DoubleLeftRightArrow", "⇔" )
    , ( "DoubleLeftTee", "⫤" )
    , ( "DoubleLongLeftArrow", "⟸" )
    , ( "DoubleLongLeftRightArrow", "⟺" )
    , ( "DoubleLongRightArrow", "⟹" )
    , ( "DoubleRightArrow", "⇒" )
    , ( "DoubleRightTee", "⊨" )
    , ( "DoubleUpArrow", "⇑" )
    , ( "DoubleUpDownArrow", "⇕" )
    , ( "DoubleVerticalBar", "∥" )
    , ( "DownArrowBar", "⤓" )
    , ( "downarrow", "↓" )
    , ( "DownArrow", "↓" )
    , ( "Downarrow", "⇓" )
    , ( "DownArrowUpArrow", "⇵" )
    , ( "DownBreve", "̑" )
    , ( "downdownarrows", "⇊" )
    , ( "downharpoonleft", "⇃" )
    , ( "downharpoonright", "⇂" )
    , ( "DownLeftRightVector", "⥐" )
    , ( "DownLeftTeeVector", "⥞" )
    , ( "DownLeftVectorBar", "⥖" )
    , ( "DownLeftVector", "↽" )
    , ( "DownRightTeeVector", "⥟" )
    , ( "DownRightVectorBar", "⥗" )
    , ( "DownRightVector", "⇁" )
    , ( "DownTeeArrow", "↧" )
    , ( "DownTee", "⊤" )
    , ( "drbkarow", "⤐" )
    , ( "drcorn", "⌟" )
    , ( "drcrop", "⌌" )
    , ( "Dscr", "\u{D835}\u{DC9F}" )
    , ( "dscr", "\u{D835}\u{DCB9}" )
    , ( "DScy", "Ѕ" )
    , ( "dscy", "ѕ" )
    , ( "dsol", "⧶" )
    , ( "Dstrok", "Đ" )
    , ( "dstrok", "đ" )
    , ( "dtdot", "⋱" )
    , ( "dtri", "▿" )
    , ( "dtrif", "▾" )
    , ( "duarr", "⇵" )
    , ( "duhar", "⥯" )
    , ( "dwangle", "⦦" )
    , ( "DZcy", "Џ" )
    , ( "dzcy", "џ" )
    , ( "dzigrarr", "⟿" )
    , ( "Eacute", "É" )
    , ( "eacute", "é" )
    , ( "easter", "⩮" )
    , ( "Ecaron", "Ě" )
    , ( "ecaron", "ě" )
    , ( "Ecirc", "Ê" )
    , ( "ecirc", "ê" )
    , ( "ecir", "≖" )
    , ( "ecolon", "≕" )
    , ( "Ecy", "Э" )
    , ( "ecy", "э" )
    , ( "eDDot", "⩷" )
    , ( "Edot", "Ė" )
    , ( "edot", "ė" )
    , ( "eDot", "≑" )
    , ( "ee", "ⅇ" )
    , ( "efDot", "≒" )
    , ( "Efr", "\u{D835}\u{DD08}" )
    , ( "efr", "\u{D835}\u{DD22}" )
    , ( "eg", "⪚" )
    , ( "Egrave", "È" )
    , ( "egrave", "è" )
    , ( "egs", "⪖" )
    , ( "egsdot", "⪘" )
    , ( "el", "⪙" )
    , ( "Element", "∈" )
    , ( "elinters", "⏧" )
    , ( "ell", "ℓ" )
    , ( "els", "⪕" )
    , ( "elsdot", "⪗" )
    , ( "Emacr", "Ē" )
    , ( "emacr", "ē" )
    , ( "empty", "∅" )
    , ( "emptyset", "∅" )
    , ( "EmptySmallSquare", "◻" )
    , ( "emptyv", "∅" )
    , ( "EmptyVerySmallSquare", "▫" )
    , ( "emsp13", "\u{2004}" )
    , ( "emsp14", "\u{2005}" )
    , ( "emsp", "\u{2003}" )
    , ( "ENG", "Ŋ" )
    , ( "eng", "ŋ" )
    , ( "ensp", "\u{2002}" )
    , ( "Eogon", "Ę" )
    , ( "eogon", "ę" )
    , ( "Eopf", "\u{D835}\u{DD3C}" )
    , ( "eopf", "\u{D835}\u{DD56}" )
    , ( "epar", "⋕" )
    , ( "eparsl", "⧣" )
    , ( "eplus", "⩱" )
    , ( "epsi", "ε" )
    , ( "Epsilon", "Ε" )
    , ( "epsilon", "ε" )
    , ( "epsiv", "ϵ" )
    , ( "eqcirc", "≖" )
    , ( "eqcolon", "≕" )
    , ( "eqsim", "≂" )
    , ( "eqslantgtr", "⪖" )
    , ( "eqslantless", "⪕" )
    , ( "Equal", "⩵" )
    , ( "equals", "=" )
    , ( "EqualTilde", "≂" )
    , ( "equest", "≟" )
    , ( "Equilibrium", "⇌" )
    , ( "equiv", "≡" )
    , ( "equivDD", "⩸" )
    , ( "eqvparsl", "⧥" )
    , ( "erarr", "⥱" )
    , ( "erDot", "≓" )
    , ( "escr", "ℯ" )
    , ( "Escr", "ℰ" )
    , ( "esdot", "≐" )
    , ( "Esim", "⩳" )
    , ( "esim", "≂" )
    , ( "Eta", "Η" )
    , ( "eta", "η" )
    , ( "ETH", "Ð" )
    , ( "eth", "ð" )
    , ( "Euml", "Ë" )
    , ( "euml", "ë" )
    , ( "euro", "€" )
    , ( "excl", "!" )
    , ( "exist", "∃" )
    , ( "Exists", "∃" )
    , ( "expectation", "ℰ" )
    , ( "exponentiale", "ⅇ" )
    , ( "ExponentialE", "ⅇ" )
    , ( "fallingdotseq", "≒" )
    , ( "Fcy", "Ф" )
    , ( "fcy", "ф" )
    , ( "female", "♀" )
    , ( "ffilig", "ﬃ" )
    , ( "fflig", "ﬀ" )
    , ( "ffllig", "ﬄ" )
    , ( "Ffr", "\u{D835}\u{DD09}" )
    , ( "ffr", "\u{D835}\u{DD23}" )
    , ( "filig", "ﬁ" )
    , ( "FilledSmallSquare", "◼" )
    , ( "FilledVerySmallSquare", "▪" )
    , ( "fjlig", "fj" )
    , ( "flat", "♭" )
    , ( "fllig", "ﬂ" )
    , ( "fltns", "▱" )
    , ( "fnof", "ƒ" )
    , ( "Fopf", "\u{D835}\u{DD3D}" )
    , ( "fopf", "\u{D835}\u{DD57}" )
    , ( "forall", "∀" )
    , ( "ForAll", "∀" )
    , ( "fork", "⋔" )
    , ( "forkv", "⫙" )
    , ( "Fouriertrf", "ℱ" )
    , ( "fpartint", "⨍" )
    , ( "frac12", "½" )
    , ( "frac13", "⅓" )
    , ( "frac14", "¼" )
    , ( "frac15", "⅕" )
    , ( "frac16", "⅙" )
    , ( "frac18", "⅛" )
    , ( "frac23", "⅔" )
    , ( "frac25", "⅖" )
    , ( "frac34", "¾" )
    , ( "frac35", "⅗" )
    , ( "frac38", "⅜" )
    , ( "frac45", "⅘" )
    , ( "frac56", "⅚" )
    , ( "frac58", "⅝" )
    , ( "frac78", "⅞" )
    , ( "frasl", "⁄" )
    , ( "frown", "⌢" )
    , ( "fscr", "\u{D835}\u{DCBB}" )
    , ( "Fscr", "ℱ" )
    , ( "gacute", "ǵ" )
    , ( "Gamma", "Γ" )
    , ( "gamma", "γ" )
    , ( "Gammad", "Ϝ" )
    , ( "gammad", "ϝ" )
    , ( "gap", "⪆" )
    , ( "Gbreve", "Ğ" )
    , ( "gbreve", "ğ" )
    , ( "Gcedil", "Ģ" )
    , ( "Gcirc", "Ĝ" )
    , ( "gcirc", "ĝ" )
    , ( "Gcy", "Г" )
    , ( "gcy", "г" )
    , ( "Gdot", "Ġ" )
    , ( "gdot", "ġ" )
    , ( "ge", "≥" )
    , ( "gE", "≧" )
    , ( "gEl", "⪌" )
    , ( "gel", "⋛" )
    , ( "geq", "≥" )
    , ( "geqq", "≧" )
    , ( "geqslant", "⩾" )
    , ( "gescc", "⪩" )
    , ( "ges", "⩾" )
    , ( "gesdot", "⪀" )
    , ( "gesdoto", "⪂" )
    , ( "gesdotol", "⪄" )
    , ( "gesl", "⋛︀" )
    , ( "gesles", "⪔" )
    , ( "Gfr", "\u{D835}\u{DD0A}" )
    , ( "gfr", "\u{D835}\u{DD24}" )
    , ( "gg", "≫" )
    , ( "Gg", "⋙" )
    , ( "ggg", "⋙" )
    , ( "gimel", "ℷ" )
    , ( "GJcy", "Ѓ" )
    , ( "gjcy", "ѓ" )
    , ( "gla", "⪥" )
    , ( "gl", "≷" )
    , ( "glE", "⪒" )
    , ( "glj", "⪤" )
    , ( "gnap", "⪊" )
    , ( "gnapprox", "⪊" )
    , ( "gne", "⪈" )
    , ( "gnE", "≩" )
    , ( "gneq", "⪈" )
    , ( "gneqq", "≩" )
    , ( "gnsim", "⋧" )
    , ( "Gopf", "\u{D835}\u{DD3E}" )
    , ( "gopf", "\u{D835}\u{DD58}" )
    , ( "grave", "`" )
    , ( "GreaterEqual", "≥" )
    , ( "GreaterEqualLess", "⋛" )
    , ( "GreaterFullEqual", "≧" )
    , ( "GreaterGreater", "⪢" )
    , ( "GreaterLess", "≷" )
    , ( "GreaterSlantEqual", "⩾" )
    , ( "GreaterTilde", "≳" )
    , ( "Gscr", "\u{D835}\u{DCA2}" )
    , ( "gscr", "ℊ" )
    , ( "gsim", "≳" )
    , ( "gsime", "⪎" )
    , ( "gsiml", "⪐" )
    , ( "gtcc", "⪧" )
    , ( "gtcir", "⩺" )
    , ( "gt", ">" )
    , ( "GT", ">" )
    , ( "Gt", "≫" )
    , ( "gtdot", "⋗" )
    , ( "gtlPar", "⦕" )
    , ( "gtquest", "⩼" )
    , ( "gtrapprox", "⪆" )
    , ( "gtrarr", "⥸" )
    , ( "gtrdot", "⋗" )
    , ( "gtreqless", "⋛" )
    , ( "gtreqqless", "⪌" )
    , ( "gtrless", "≷" )
    , ( "gtrsim", "≳" )
    , ( "gvertneqq", "≩︀" )
    , ( "gvnE", "≩︀" )
    , ( "Hacek", "ˇ" )
    , ( "hairsp", "\u{200A}" )
    , ( "half", "½" )
    , ( "hamilt", "ℋ" )
    , ( "HARDcy", "Ъ" )
    , ( "hardcy", "ъ" )
    , ( "harrcir", "⥈" )
    , ( "harr", "↔" )
    , ( "hArr", "⇔" )
    , ( "harrw", "↭" )
    , ( "Hat", "^" )
    , ( "hbar", "ℏ" )
    , ( "Hcirc", "Ĥ" )
    , ( "hcirc", "ĥ" )
    , ( "hearts", "♥" )
    , ( "heartsuit", "♥" )
    , ( "hellip", "…" )
    , ( "hercon", "⊹" )
    , ( "hfr", "\u{D835}\u{DD25}" )
    , ( "Hfr", "ℌ" )
    , ( "HilbertSpace", "ℋ" )
    , ( "hksearow", "⤥" )
    , ( "hkswarow", "⤦" )
    , ( "hoarr", "⇿" )
    , ( "homtht", "∻" )
    , ( "hookleftarrow", "↩" )
    , ( "hookrightarrow", "↪" )
    , ( "hopf", "\u{D835}\u{DD59}" )
    , ( "Hopf", "ℍ" )
    , ( "horbar", "―" )
    , ( "HorizontalLine", "─" )
    , ( "hscr", "\u{D835}\u{DCBD}" )
    , ( "Hscr", "ℋ" )
    , ( "hslash", "ℏ" )
    , ( "Hstrok", "Ħ" )
    , ( "hstrok", "ħ" )
    , ( "HumpDownHump", "≎" )
    , ( "HumpEqual", "≏" )
    , ( "hybull", "⁃" )
    , ( "hyphen", "‐" )
    , ( "Iacute", "Í" )
    , ( "iacute", "í" )
    , ( "ic", "\u{2063}" )
    , ( "Icirc", "Î" )
    , ( "icirc", "î" )
    , ( "Icy", "И" )
    , ( "icy", "и" )
    , ( "Idot", "İ" )
    , ( "IEcy", "Е" )
    , ( "iecy", "е" )
    , ( "iexcl", "¡" )
    , ( "iff", "⇔" )
    , ( "ifr", "\u{D835}\u{DD26}" )
    , ( "Ifr", "ℑ" )
    , ( "Igrave", "Ì" )
    , ( "igrave", "ì" )
    , ( "ii", "ⅈ" )
    , ( "iiiint", "⨌" )
    , ( "iiint", "∭" )
    , ( "iinfin", "⧜" )
    , ( "iiota", "℩" )
    , ( "IJlig", "Ĳ" )
    , ( "ijlig", "ĳ" )
    , ( "Imacr", "Ī" )
    , ( "imacr", "ī" )
    , ( "image", "ℑ" )
    , ( "ImaginaryI", "ⅈ" )
    , ( "imagline", "ℐ" )
    , ( "imagpart", "ℑ" )
    , ( "imath", "ı" )
    , ( "Im", "ℑ" )
    , ( "imof", "⊷" )
    , ( "imped", "Ƶ" )
    , ( "Implies", "⇒" )
    , ( "incare", "℅" )
    , ( "in", "∈" )
    , ( "infin", "∞" )
    , ( "infintie", "⧝" )
    , ( "inodot", "ı" )
    , ( "intcal", "⊺" )
    , ( "int", "∫" )
    , ( "Int", "∬" )
    , ( "integers", "ℤ" )
    , ( "Integral", "∫" )
    , ( "intercal", "⊺" )
    , ( "Intersection", "⋂" )
    , ( "intlarhk", "⨗" )
    , ( "intprod", "⨼" )
    , ( "InvisibleComma", "\u{2063}" )
    , ( "InvisibleTimes", "\u{2062}" )
    , ( "IOcy", "Ё" )
    , ( "iocy", "ё" )
    , ( "Iogon", "Į" )
    , ( "iogon", "į" )
    , ( "Iopf", "\u{D835}\u{DD40}" )
    , ( "iopf", "\u{D835}\u{DD5A}" )
    , ( "Iota", "Ι" )
    , ( "iota", "ι" )
    , ( "iprod", "⨼" )
    , ( "iquest", "¿" )
    , ( "iscr", "\u{D835}\u{DCBE}" )
    , ( "Iscr", "ℐ" )
    , ( "isin", "∈" )
    , ( "isindot", "⋵" )
    , ( "isinE", "⋹" )
    , ( "isins", "⋴" )
    , ( "isinsv", "⋳" )
    , ( "isinv", "∈" )
    , ( "it", "\u{2062}" )
    , ( "Itilde", "Ĩ" )
    , ( "itilde", "ĩ" )
    , ( "Iukcy", "І" )
    , ( "iukcy", "і" )
    , ( "Iuml", "Ï" )
    , ( "iuml", "ï" )
    , ( "Jcirc", "Ĵ" )
    , ( "jcirc", "ĵ" )
    , ( "Jcy", "Й" )
    , ( "jcy", "й" )
    , ( "Jfr", "\u{D835}\u{DD0D}" )
    , ( "jfr", "\u{D835}\u{DD27}" )
    , ( "jmath", "ȷ" )
    , ( "Jopf", "\u{D835}\u{DD41}" )
    , ( "jopf", "\u{D835}\u{DD5B}" )
    , ( "Jscr", "\u{D835}\u{DCA5}" )
    , ( "jscr", "\u{D835}\u{DCBF}" )
    , ( "Jsercy", "Ј" )
    , ( "jsercy", "ј" )
    , ( "Jukcy", "Є" )
    , ( "jukcy", "є" )
    , ( "Kappa", "Κ" )
    , ( "kappa", "κ" )
    , ( "kappav", "ϰ" )
    , ( "Kcedil", "Ķ" )
    , ( "kcedil", "ķ" )
    , ( "Kcy", "К" )
    , ( "kcy", "к" )
    , ( "Kfr", "\u{D835}\u{DD0E}" )
    , ( "kfr", "\u{D835}\u{DD28}" )
    , ( "kgreen", "ĸ" )
    , ( "KHcy", "Х" )
    , ( "khcy", "х" )
    , ( "KJcy", "Ќ" )
    , ( "kjcy", "ќ" )
    , ( "Kopf", "\u{D835}\u{DD42}" )
    , ( "kopf", "\u{D835}\u{DD5C}" )
    , ( "Kscr", "\u{D835}\u{DCA6}" )
    , ( "kscr", "\u{D835}\u{DCC0}" )
    , ( "lAarr", "⇚" )
    , ( "Lacute", "Ĺ" )
    , ( "lacute", "ĺ" )
    , ( "laemptyv", "⦴" )
    , ( "lagran", "ℒ" )
    , ( "Lambda", "Λ" )
    , ( "lambda", "λ" )
    , ( "lang", "⟨" )
    , ( "Lang", "⟪" )
    , ( "langd", "⦑" )
    , ( "langle", "⟨" )
    , ( "lap", "⪅" )
    , ( "Laplacetrf", "ℒ" )
    , ( "laquo", "«" )
    , ( "larrb", "⇤" )
    , ( "larrbfs", "⤟" )
    , ( "larr", "←" )
    , ( "Larr", "↞" )
    , ( "lArr", "⇐" )
    , ( "larrfs", "⤝" )
    , ( "larrhk", "↩" )
    , ( "larrlp", "↫" )
    , ( "larrpl", "⤹" )
    , ( "larrsim", "⥳" )
    , ( "larrtl", "↢" )
    , ( "latail", "⤙" )
    , ( "lAtail", "⤛" )
    , ( "lat", "⪫" )
    , ( "late", "⪭" )
    , ( "lates", "⪭︀" )
    , ( "lbarr", "⤌" )
    , ( "lBarr", "⤎" )
    , ( "lbbrk", "❲" )
    , ( "lbrace", "{" )
    , ( "lbrack", "[" )
    , ( "lbrke", "⦋" )
    , ( "lbrksld", "⦏" )
    , ( "lbrkslu", "⦍" )
    , ( "Lcaron", "Ľ" )
    , ( "lcaron", "ľ" )
    , ( "Lcedil", "Ļ" )
    , ( "lcedil", "ļ" )
    , ( "lceil", "⌈" )
    , ( "lcub", "{" )
    , ( "Lcy", "Л" )
    , ( "lcy", "л" )
    , ( "ldca", "⤶" )
    , ( "ldquo", "“" )
    , ( "ldquor", "„" )
    , ( "ldrdhar", "⥧" )
    , ( "ldrushar", "⥋" )
    , ( "ldsh", "↲" )
    , ( "le", "≤" )
    , ( "lE", "≦" )
    , ( "LeftAngleBracket", "⟨" )
    , ( "LeftArrowBar", "⇤" )
    , ( "leftarrow", "←" )
    , ( "LeftArrow", "←" )
    , ( "Leftarrow", "⇐" )
    , ( "LeftArrowRightArrow", "⇆" )
    , ( "leftarrowtail", "↢" )
    , ( "LeftCeiling", "⌈" )
    , ( "LeftDoubleBracket", "⟦" )
    , ( "LeftDownTeeVector", "⥡" )
    , ( "LeftDownVectorBar", "⥙" )
    , ( "LeftDownVector", "⇃" )
    , ( "LeftFloor", "⌊" )
    , ( "leftharpoondown", "↽" )
    , ( "leftharpoonup", "↼" )
    , ( "leftleftarrows", "⇇" )
    , ( "leftrightarrow", "↔" )
    , ( "LeftRightArrow", "↔" )
    , ( "Leftrightarrow", "⇔" )
    , ( "leftrightarrows", "⇆" )
    , ( "leftrightharpoons", "⇋" )
    , ( "leftrightsquigarrow", "↭" )
    , ( "LeftRightVector", "⥎" )
    , ( "LeftTeeArrow", "↤" )
    , ( "LeftTee", "⊣" )
    , ( "LeftTeeVector", "⥚" )
    , ( "leftthreetimes", "⋋" )
    , ( "LeftTriangleBar", "⧏" )
    , ( "LeftTriangle", "⊲" )
    , ( "LeftTriangleEqual", "⊴" )
    , ( "LeftUpDownVector", "⥑" )
    , ( "LeftUpTeeVector", "⥠" )
    , ( "LeftUpVectorBar", "⥘" )
    , ( "LeftUpVector", "↿" )
    , ( "LeftVectorBar", "⥒" )
    , ( "LeftVector", "↼" )
    , ( "lEg", "⪋" )
    , ( "leg", "⋚" )
    , ( "leq", "≤" )
    , ( "leqq", "≦" )
    , ( "leqslant", "⩽" )
    , ( "lescc", "⪨" )
    , ( "les", "⩽" )
    , ( "lesdot", "⩿" )
    , ( "lesdoto", "⪁" )
    , ( "lesdotor", "⪃" )
    , ( "lesg", "⋚︀" )
    , ( "lesges", "⪓" )
    , ( "lessapprox", "⪅" )
    , ( "lessdot", "⋖" )
    , ( "lesseqgtr", "⋚" )
    , ( "lesseqqgtr", "⪋" )
    , ( "LessEqualGreater", "⋚" )
    , ( "LessFullEqual", "≦" )
    , ( "LessGreater", "≶" )
    , ( "lessgtr", "≶" )
    , ( "LessLess", "⪡" )
    , ( "lesssim", "≲" )
    , ( "LessSlantEqual", "⩽" )
    , ( "LessTilde", "≲" )
    , ( "lfisht", "⥼" )
    , ( "lfloor", "⌊" )
    , ( "Lfr", "\u{D835}\u{DD0F}" )
    , ( "lfr", "\u{D835}\u{DD29}" )
    , ( "lg", "≶" )
    , ( "lgE", "⪑" )
    , ( "lHar", "⥢" )
    , ( "lhard", "↽" )
    , ( "lharu", "↼" )
    , ( "lharul", "⥪" )
    , ( "lhblk", "▄" )
    , ( "LJcy", "Љ" )
    , ( "ljcy", "љ" )
    , ( "llarr", "⇇" )
    , ( "ll", "≪" )
    , ( "Ll", "⋘" )
    , ( "llcorner", "⌞" )
    , ( "Lleftarrow", "⇚" )
    , ( "llhard", "⥫" )
    , ( "lltri", "◺" )
    , ( "Lmidot", "Ŀ" )
    , ( "lmidot", "ŀ" )
    , ( "lmoustache", "⎰" )
    , ( "lmoust", "⎰" )
    , ( "lnap", "⪉" )
    , ( "lnapprox", "⪉" )
    , ( "lne", "⪇" )
    , ( "lnE", "≨" )
    , ( "lneq", "⪇" )
    , ( "lneqq", "≨" )
    , ( "lnsim", "⋦" )
    , ( "loang", "⟬" )
    , ( "loarr", "⇽" )
    , ( "lobrk", "⟦" )
    , ( "longleftarrow", "⟵" )
    , ( "LongLeftArrow", "⟵" )
    , ( "Longleftarrow", "⟸" )
    , ( "longleftrightarrow", "⟷" )
    , ( "LongLeftRightArrow", "⟷" )
    , ( "Longleftrightarrow", "⟺" )
    , ( "longmapsto", "⟼" )
    , ( "longrightarrow", "⟶" )
    , ( "LongRightArrow", "⟶" )
    , ( "Longrightarrow", "⟹" )
    , ( "looparrowleft", "↫" )
    , ( "looparrowright", "↬" )
    , ( "lopar", "⦅" )
    , ( "Lopf", "\u{D835}\u{DD43}" )
    , ( "lopf", "\u{D835}\u{DD5D}" )
    , ( "loplus", "⨭" )
    , ( "lotimes", "⨴" )
    , ( "lowast", "∗" )
    , ( "lowbar", "_" )
    , ( "LowerLeftArrow", "↙" )
    , ( "LowerRightArrow", "↘" )
    , ( "loz", "◊" )
    , ( "lozenge", "◊" )
    , ( "lozf", "⧫" )
    , ( "lpar", "(" )
    , ( "lparlt", "⦓" )
    , ( "lrarr", "⇆" )
    , ( "lrcorner", "⌟" )
    , ( "lrhar", "⇋" )
    , ( "lrhard", "⥭" )
    , ( "lrm", "\u{200E}" )
    , ( "lrtri", "⊿" )
    , ( "lsaquo", "‹" )
    , ( "lscr", "\u{D835}\u{DCC1}" )
    , ( "Lscr", "ℒ" )
    , ( "lsh", "↰" )
    , ( "Lsh", "↰" )
    , ( "lsim", "≲" )
    , ( "lsime", "⪍" )
    , ( "lsimg", "⪏" )
    , ( "lsqb", "[" )
    , ( "lsquo", "‘" )
    , ( "lsquor", "‚" )
    , ( "Lstrok", "Ł" )
    , ( "lstrok", "ł" )
    , ( "ltcc", "⪦" )
    , ( "ltcir", "⩹" )
    , ( "lt", "<" )
    , ( "LT", "<" )
    , ( "Lt", "≪" )
    , ( "ltdot", "⋖" )
    , ( "lthree", "⋋" )
    , ( "ltimes", "⋉" )
    , ( "ltlarr", "⥶" )
    , ( "ltquest", "⩻" )
    , ( "ltri", "◃" )
    , ( "ltrie", "⊴" )
    , ( "ltrif", "◂" )
    , ( "ltrPar", "⦖" )
    , ( "lurdshar", "⥊" )
    , ( "luruhar", "⥦" )
    , ( "lvertneqq", "≨︀" )
    , ( "lvnE", "≨︀" )
    , ( "macr", "¯" )
    , ( "male", "♂" )
    , ( "malt", "✠" )
    , ( "maltese", "✠" )
    , ( "Map", "⤅" )
    , ( "map", "↦" )
    , ( "mapsto", "↦" )
    , ( "mapstodown", "↧" )
    , ( "mapstoleft", "↤" )
    , ( "mapstoup", "↥" )
    , ( "marker", "▮" )
    , ( "mcomma", "⨩" )
    , ( "Mcy", "М" )
    , ( "mcy", "м" )
    , ( "mdash", "—" )
    , ( "mDDot", "∺" )
    , ( "measuredangle", "∡" )
    , ( "MediumSpace", "\u{205F}" )
    , ( "Mellintrf", "ℳ" )
    , ( "Mfr", "\u{D835}\u{DD10}" )
    , ( "mfr", "\u{D835}\u{DD2A}" )
    , ( "mho", "℧" )
    , ( "micro", "µ" )
    , ( "midast", "*" )
    , ( "midcir", "⫰" )
    , ( "mid", "∣" )
    , ( "middot", "·" )
    , ( "minusb", "⊟" )
    , ( "minus", "−" )
    , ( "minusd", "∸" )
    , ( "minusdu", "⨪" )
    , ( "MinusPlus", "∓" )
    , ( "mlcp", "⫛" )
    , ( "mldr", "…" )
    , ( "mnplus", "∓" )
    , ( "models", "⊧" )
    , ( "Mopf", "\u{D835}\u{DD44}" )
    , ( "mopf", "\u{D835}\u{DD5E}" )
    , ( "mp", "∓" )
    , ( "mscr", "\u{D835}\u{DCC2}" )
    , ( "Mscr", "ℳ" )
    , ( "mstpos", "∾" )
    , ( "Mu", "Μ" )
    , ( "mu", "μ" )
    , ( "multimap", "⊸" )
    , ( "mumap", "⊸" )
    , ( "nabla", "∇" )
    , ( "Nacute", "Ń" )
    , ( "nacute", "ń" )
    , ( "nang", "∠⃒" )
    , ( "nap", "≉" )
    , ( "napE", "⩰̸" )
    , ( "napid", "≋̸" )
    , ( "napos", "ŉ" )
    , ( "napprox", "≉" )
    , ( "natural", "♮" )
    , ( "naturals", "ℕ" )
    , ( "natur", "♮" )
    , ( "nbsp", "\u{00A0}" )
    , ( "nbump", "≎̸" )
    , ( "nbumpe", "≏̸" )
    , ( "ncap", "⩃" )
    , ( "Ncaron", "Ň" )
    , ( "ncaron", "ň" )
    , ( "Ncedil", "Ņ" )
    , ( "ncedil", "ņ" )
    , ( "ncong", "≇" )
    , ( "ncongdot", "⩭̸" )
    , ( "ncup", "⩂" )
    , ( "Ncy", "Н" )
    , ( "ncy", "н" )
    , ( "ndash", "–" )
    , ( "nearhk", "⤤" )
    , ( "nearr", "↗" )
    , ( "neArr", "⇗" )
    , ( "nearrow", "↗" )
    , ( "ne", "≠" )
    , ( "nedot", "≐̸" )
    , ( "NegativeMediumSpace", "\u{200B}" )
    , ( "NegativeThickSpace", "\u{200B}" )
    , ( "NegativeThinSpace", "\u{200B}" )
    , ( "NegativeVeryThinSpace", "\u{200B}" )
    , ( "nequiv", "≢" )
    , ( "nesear", "⤨" )
    , ( "nesim", "≂̸" )
    , ( "NestedGreaterGreater", "≫" )
    , ( "NestedLessLess", "≪" )
    , ( "NewLine", "\n" )
    , ( "nexist", "∄" )
    , ( "nexists", "∄" )
    , ( "Nfr", "\u{D835}\u{DD11}" )
    , ( "nfr", "\u{D835}\u{DD2B}" )
    , ( "ngE", "≧̸" )
    , ( "nge", "≱" )
    , ( "ngeq", "≱" )
    , ( "ngeqq", "≧̸" )
    , ( "ngeqslant", "⩾̸" )
    , ( "nges", "⩾̸" )
    , ( "nGg", "⋙̸" )
    , ( "ngsim", "≵" )
    , ( "nGt", "≫⃒" )
    , ( "ngt", "≯" )
    , ( "ngtr", "≯" )
    , ( "nGtv", "≫̸" )
    , ( "nharr", "↮" )
    , ( "nhArr", "⇎" )
    , ( "nhpar", "⫲" )
    , ( "ni", "∋" )
    , ( "nis", "⋼" )
    , ( "nisd", "⋺" )
    , ( "niv", "∋" )
    , ( "NJcy", "Њ" )
    , ( "njcy", "њ" )
    , ( "nlarr", "↚" )
    , ( "nlArr", "⇍" )
    , ( "nldr", "‥" )
    , ( "nlE", "≦̸" )
    , ( "nle", "≰" )
    , ( "nleftarrow", "↚" )
    , ( "nLeftarrow", "⇍" )
    , ( "nleftrightarrow", "↮" )
    , ( "nLeftrightarrow", "⇎" )
    , ( "nleq", "≰" )
    , ( "nleqq", "≦̸" )
    , ( "nleqslant", "⩽̸" )
    , ( "nles", "⩽̸" )
    , ( "nless", "≮" )
    , ( "nLl", "⋘̸" )
    , ( "nlsim", "≴" )
    , ( "nLt", "≪⃒" )
    , ( "nlt", "≮" )
    , ( "nltri", "⋪" )
    , ( "nltrie", "⋬" )
    , ( "nLtv", "≪̸" )
    , ( "nmid", "∤" )
    , ( "NoBreak", "\u{2060}" )
    , ( "NonBreakingSpace", "\u{00A0}" )
    , ( "nopf", "\u{D835}\u{DD5F}" )
    , ( "Nopf", "ℕ" )
    , ( "Not", "⫬" )
    , ( "not", "¬" )
    , ( "NotCongruent", "≢" )
    , ( "NotCupCap", "≭" )
    , ( "NotDoubleVerticalBar", "∦" )
    , ( "NotElement", "∉" )
    , ( "NotEqual", "≠" )
    , ( "NotEqualTilde", "≂̸" )
    , ( "NotExists", "∄" )
    , ( "NotGreater", "≯" )
    , ( "NotGreaterEqual", "≱" )
    , ( "NotGreaterFullEqual", "≧̸" )
    , ( "NotGreaterGreater", "≫̸" )
    , ( "NotGreaterLess", "≹" )
    , ( "NotGreaterSlantEqual", "⩾̸" )
    , ( "NotGreaterTilde", "≵" )
    , ( "NotHumpDownHump", "≎̸" )
    , ( "NotHumpEqual", "≏̸" )
    , ( "notin", "∉" )
    , ( "notindot", "⋵̸" )
    , ( "notinE", "⋹̸" )
    , ( "notinva", "∉" )
    , ( "notinvb", "⋷" )
    , ( "notinvc", "⋶" )
    , ( "NotLeftTriangleBar", "⧏̸" )
    , ( "NotLeftTriangle", "⋪" )
    , ( "NotLeftTriangleEqual", "⋬" )
    , ( "NotLess", "≮" )
    , ( "NotLessEqual", "≰" )
    , ( "NotLessGreater", "≸" )
    , ( "NotLessLess", "≪̸" )
    , ( "NotLessSlantEqual", "⩽̸" )
    , ( "NotLessTilde", "≴" )
    , ( "NotNestedGreaterGreater", "⪢̸" )
    , ( "NotNestedLessLess", "⪡̸" )
    , ( "notni", "∌" )
    , ( "notniva", "∌" )
    , ( "notnivb", "⋾" )
    , ( "notnivc", "⋽" )
    , ( "NotPrecedes", "⊀" )
    , ( "NotPrecedesEqual", "⪯̸" )
    , ( "NotPrecedesSlantEqual", "⋠" )
    , ( "NotReverseElement", "∌" )
    , ( "NotRightTriangleBar", "⧐̸" )
    , ( "NotRightTriangle", "⋫" )
    , ( "NotRightTriangleEqual", "⋭" )
    , ( "NotSquareSubset", "⊏̸" )
    , ( "NotSquareSubsetEqual", "⋢" )
    , ( "NotSquareSuperset", "⊐̸" )
    , ( "NotSquareSupersetEqual", "⋣" )
    , ( "NotSubset", "⊂⃒" )
    , ( "NotSubsetEqual", "⊈" )
    , ( "NotSucceeds", "⊁" )
    , ( "NotSucceedsEqual", "⪰̸" )
    , ( "NotSucceedsSlantEqual", "⋡" )
    , ( "NotSucceedsTilde", "≿̸" )
    , ( "NotSuperset", "⊃⃒" )
    , ( "NotSupersetEqual", "⊉" )
    , ( "NotTilde", "≁" )
    , ( "NotTildeEqual", "≄" )
    , ( "NotTildeFullEqual", "≇" )
    , ( "NotTildeTilde", "≉" )
    , ( "NotVerticalBar", "∤" )
    , ( "nparallel", "∦" )
    , ( "npar", "∦" )
    , ( "nparsl", "⫽⃥" )
    , ( "npart", "∂̸" )
    , ( "npolint", "⨔" )
    , ( "npr", "⊀" )
    , ( "nprcue", "⋠" )
    , ( "nprec", "⊀" )
    , ( "npreceq", "⪯̸" )
    , ( "npre", "⪯̸" )
    , ( "nrarrc", "⤳̸" )
    , ( "nrarr", "↛" )
    , ( "nrArr", "⇏" )
    , ( "nrarrw", "↝̸" )
    , ( "nrightarrow", "↛" )
    , ( "nRightarrow", "⇏" )
    , ( "nrtri", "⋫" )
    , ( "nrtrie", "⋭" )
    , ( "nsc", "⊁" )
    , ( "nsccue", "⋡" )
    , ( "nsce", "⪰̸" )
    , ( "Nscr", "\u{D835}\u{DCA9}" )
    , ( "nscr", "\u{D835}\u{DCC3}" )
    , ( "nshortmid", "∤" )
    , ( "nshortparallel", "∦" )
    , ( "nsim", "≁" )
    , ( "nsime", "≄" )
    , ( "nsimeq", "≄" )
    , ( "nsmid", "∤" )
    , ( "nspar", "∦" )
    , ( "nsqsube", "⋢" )
    , ( "nsqsupe", "⋣" )
    , ( "nsub", "⊄" )
    , ( "nsubE", "⫅̸" )
    , ( "nsube", "⊈" )
    , ( "nsubset", "⊂⃒" )
    , ( "nsubseteq", "⊈" )
    , ( "nsubseteqq", "⫅̸" )
    , ( "nsucc", "⊁" )
    , ( "nsucceq", "⪰̸" )
    , ( "nsup", "⊅" )
    , ( "nsupE", "⫆̸" )
    , ( "nsupe", "⊉" )
    , ( "nsupset", "⊃⃒" )
    , ( "nsupseteq", "⊉" )
    , ( "nsupseteqq", "⫆̸" )
    , ( "ntgl", "≹" )
    , ( "Ntilde", "Ñ" )
    , ( "ntilde", "ñ" )
    , ( "ntlg", "≸" )
    , ( "ntriangleleft", "⋪" )
    , ( "ntrianglelefteq", "⋬" )
    , ( "ntriangleright", "⋫" )
    , ( "ntrianglerighteq", "⋭" )
    , ( "Nu", "Ν" )
    , ( "nu", "ν" )
    , ( "num", "#" )
    , ( "numero", "№" )
    , ( "numsp", "\u{2007}" )
    , ( "nvap", "≍⃒" )
    , ( "nvdash", "⊬" )
    , ( "nvDash", "⊭" )
    , ( "nVdash", "⊮" )
    , ( "nVDash", "⊯" )
    , ( "nvge", "≥⃒" )
    , ( "nvgt", ">⃒" )
    , ( "nvHarr", "⤄" )
    , ( "nvinfin", "⧞" )
    , ( "nvlArr", "⤂" )
    , ( "nvle", "≤⃒" )
    , ( "nvlt", "<⃒" )
    , ( "nvltrie", "⊴⃒" )
    , ( "nvrArr", "⤃" )
    , ( "nvrtrie", "⊵⃒" )
    , ( "nvsim", "∼⃒" )
    , ( "nwarhk", "⤣" )
    , ( "nwarr", "↖" )
    , ( "nwArr", "⇖" )
    , ( "nwarrow", "↖" )
    , ( "nwnear", "⤧" )
    , ( "Oacute", "Ó" )
    , ( "oacute", "ó" )
    , ( "oast", "⊛" )
    , ( "Ocirc", "Ô" )
    , ( "ocirc", "ô" )
    , ( "ocir", "⊚" )
    , ( "Ocy", "О" )
    , ( "ocy", "о" )
    , ( "odash", "⊝" )
    , ( "Odblac", "Ő" )
    , ( "odblac", "ő" )
    , ( "odiv", "⨸" )
    , ( "odot", "⊙" )
    , ( "odsold", "⦼" )
    , ( "OElig", "Œ" )
    , ( "oelig", "œ" )
    , ( "ofcir", "⦿" )
    , ( "Ofr", "\u{D835}\u{DD12}" )
    , ( "ofr", "\u{D835}\u{DD2C}" )
    , ( "ogon", "˛" )
    , ( "Ograve", "Ò" )
    , ( "ograve", "ò" )
    , ( "ogt", "⧁" )
    , ( "ohbar", "⦵" )
    , ( "ohm", "Ω" )
    , ( "oint", "∮" )
    , ( "olarr", "↺" )
    , ( "olcir", "⦾" )
    , ( "olcross", "⦻" )
    , ( "oline", "‾" )
    , ( "olt", "⧀" )
    , ( "Omacr", "Ō" )
    , ( "omacr", "ō" )
    , ( "Omega", "Ω" )
    , ( "omega", "ω" )
    , ( "Omicron", "Ο" )
    , ( "omicron", "ο" )
    , ( "omid", "⦶" )
    , ( "ominus", "⊖" )
    , ( "Oopf", "\u{D835}\u{DD46}" )
    , ( "oopf", "\u{D835}\u{DD60}" )
    , ( "opar", "⦷" )
    , ( "OpenCurlyDoubleQuote", "“" )
    , ( "OpenCurlyQuote", "‘" )
    , ( "operp", "⦹" )
    , ( "oplus", "⊕" )
    , ( "orarr", "↻" )
    , ( "Or", "⩔" )
    , ( "or", "∨" )
    , ( "ord", "⩝" )
    , ( "order", "ℴ" )
    , ( "orderof", "ℴ" )
    , ( "ordf", "ª" )
    , ( "ordm", "º" )
    , ( "origof", "⊶" )
    , ( "oror", "⩖" )
    , ( "orslope", "⩗" )
    , ( "orv", "⩛" )
    , ( "oS", "Ⓢ" )
    , ( "Oscr", "\u{D835}\u{DCAA}" )
    , ( "oscr", "ℴ" )
    , ( "Oslash", "Ø" )
    , ( "oslash", "ø" )
    , ( "osol", "⊘" )
    , ( "Otilde", "Õ" )
    , ( "otilde", "õ" )
    , ( "otimesas", "⨶" )
    , ( "Otimes", "⨷" )
    , ( "otimes", "⊗" )
    , ( "Ouml", "Ö" )
    , ( "ouml", "ö" )
    , ( "ovbar", "⌽" )
    , ( "OverBar", "‾" )
    , ( "OverBrace", "⏞" )
    , ( "OverBracket", "⎴" )
    , ( "OverParenthesis", "⏜" )
    , ( "para", "¶" )
    , ( "parallel", "∥" )
    , ( "par", "∥" )
    , ( "parsim", "⫳" )
    , ( "parsl", "⫽" )
    , ( "part", "∂" )
    , ( "PartialD", "∂" )
    , ( "Pcy", "П" )
    , ( "pcy", "п" )
    , ( "percnt", "%" )
    , ( "period", "." )
    , ( "permil", "‰" )
    , ( "perp", "⊥" )
    , ( "pertenk", "‱" )
    , ( "Pfr", "\u{D835}\u{DD13}" )
    , ( "pfr", "\u{D835}\u{DD2D}" )
    , ( "Phi", "Φ" )
    , ( "phi", "φ" )
    , ( "phiv", "ϕ" )
    , ( "phmmat", "ℳ" )
    , ( "phone", "☎" )
    , ( "Pi", "Π" )
    , ( "pi", "π" )
    , ( "pitchfork", "⋔" )
    , ( "piv", "ϖ" )
    , ( "planck", "ℏ" )
    , ( "planckh", "ℎ" )
    , ( "plankv", "ℏ" )
    , ( "plusacir", "⨣" )
    , ( "plusb", "⊞" )
    , ( "pluscir", "⨢" )
    , ( "plus", "+" )
    , ( "plusdo", "∔" )
    , ( "plusdu", "⨥" )
    , ( "pluse", "⩲" )
    , ( "PlusMinus", "±" )
    , ( "plusmn", "±" )
    , ( "plussim", "⨦" )
    , ( "plustwo", "⨧" )
    , ( "pm", "±" )
    , ( "Poincareplane", "ℌ" )
    , ( "pointint", "⨕" )
    , ( "popf", "\u{D835}\u{DD61}" )
    , ( "Popf", "ℙ" )
    , ( "pound", "£" )
    , ( "prap", "⪷" )
    , ( "Pr", "⪻" )
    , ( "pr", "≺" )
    , ( "prcue", "≼" )
    , ( "precapprox", "⪷" )
    , ( "prec", "≺" )
    , ( "preccurlyeq", "≼" )
    , ( "Precedes", "≺" )
    , ( "PrecedesEqual", "⪯" )
    , ( "PrecedesSlantEqual", "≼" )
    , ( "PrecedesTilde", "≾" )
    , ( "preceq", "⪯" )
    , ( "precnapprox", "⪹" )
    , ( "precneqq", "⪵" )
    , ( "precnsim", "⋨" )
    , ( "pre", "⪯" )
    , ( "prE", "⪳" )
    , ( "precsim", "≾" )
    , ( "prime", "′" )
    , ( "Prime", "″" )
    , ( "primes", "ℙ" )
    , ( "prnap", "⪹" )
    , ( "prnE", "⪵" )
    , ( "prnsim", "⋨" )
    , ( "prod", "∏" )
    , ( "Product", "∏" )
    , ( "profalar", "⌮" )
    , ( "profline", "⌒" )
    , ( "profsurf", "⌓" )
    , ( "prop", "∝" )
    , ( "Proportional", "∝" )
    , ( "Proportion", "∷" )
    , ( "propto", "∝" )
    , ( "prsim", "≾" )
    , ( "prurel", "⊰" )
    , ( "Pscr", "\u{D835}\u{DCAB}" )
    , ( "pscr", "\u{D835}\u{DCC5}" )
    , ( "Psi", "Ψ" )
    , ( "psi", "ψ" )
    , ( "puncsp", "\u{2008}" )
    , ( "Qfr", "\u{D835}\u{DD14}" )
    , ( "qfr", "\u{D835}\u{DD2E}" )
    , ( "qint", "⨌" )
    , ( "qopf", "\u{D835}\u{DD62}" )
    , ( "Qopf", "ℚ" )
    , ( "qprime", "⁗" )
    , ( "Qscr", "\u{D835}\u{DCAC}" )
    , ( "qscr", "\u{D835}\u{DCC6}" )
    , ( "quaternions", "ℍ" )
    , ( "quatint", "⨖" )
    , ( "quest", "?" )
    , ( "questeq", "≟" )
    , ( "quot", "\"" )
    , ( "QUOT", "\"" )
    , ( "rAarr", "⇛" )
    , ( "race", "∽̱" )
    , ( "Racute", "Ŕ" )
    , ( "racute", "ŕ" )
    , ( "radic", "√" )
    , ( "raemptyv", "⦳" )
    , ( "rang", "⟩" )
    , ( "Rang", "⟫" )
    , ( "rangd", "⦒" )
    , ( "range", "⦥" )
    , ( "rangle", "⟩" )
    , ( "raquo", "»" )
    , ( "rarrap", "⥵" )
    , ( "rarrb", "⇥" )
    , ( "rarrbfs", "⤠" )
    , ( "rarrc", "⤳" )
    , ( "rarr", "→" )
    , ( "Rarr", "↠" )
    , ( "rArr", "⇒" )
    , ( "rarrfs", "⤞" )
    , ( "rarrhk", "↪" )
    , ( "rarrlp", "↬" )
    , ( "rarrpl", "⥅" )
    , ( "rarrsim", "⥴" )
    , ( "Rarrtl", "⤖" )
    , ( "rarrtl", "↣" )
    , ( "rarrw", "↝" )
    , ( "ratail", "⤚" )
    , ( "rAtail", "⤜" )
    , ( "ratio", "∶" )
    , ( "rationals", "ℚ" )
    , ( "rbarr", "⤍" )
    , ( "rBarr", "⤏" )
    , ( "RBarr", "⤐" )
    , ( "rbbrk", "❳" )
    , ( "rbrace", "}" )
    , ( "rbrack", "]" )
    , ( "rbrke", "⦌" )
    , ( "rbrksld", "⦎" )
    , ( "rbrkslu", "⦐" )
    , ( "Rcaron", "Ř" )
    , ( "rcaron", "ř" )
    , ( "Rcedil", "Ŗ" )
    , ( "rcedil", "ŗ" )
    , ( "rceil", "⌉" )
    , ( "rcub", "}" )
    , ( "Rcy", "Р" )
    , ( "rcy", "р" )
    , ( "rdca", "⤷" )
    , ( "rdldhar", "⥩" )
    , ( "rdquo", "”" )
    , ( "rdquor", "”" )
    , ( "rdsh", "↳" )
    , ( "real", "ℜ" )
    , ( "realine", "ℛ" )
    , ( "realpart", "ℜ" )
    , ( "reals", "ℝ" )
    , ( "Re", "ℜ" )
    , ( "rect", "▭" )
    , ( "reg", "®" )
    , ( "REG", "®" )
    , ( "ReverseElement", "∋" )
    , ( "ReverseEquilibrium", "⇋" )
    , ( "ReverseUpEquilibrium", "⥯" )
    , ( "rfisht", "⥽" )
    , ( "rfloor", "⌋" )
    , ( "rfr", "\u{D835}\u{DD2F}" )
    , ( "Rfr", "ℜ" )
    , ( "rHar", "⥤" )
    , ( "rhard", "⇁" )
    , ( "rharu", "⇀" )
    , ( "rharul", "⥬" )
    , ( "Rho", "Ρ" )
    , ( "rho", "ρ" )
    , ( "rhov", "ϱ" )
    , ( "RightAngleBracket", "⟩" )
    , ( "RightArrowBar", "⇥" )
    , ( "rightarrow", "→" )
    , ( "RightArrow", "→" )
    , ( "Rightarrow", "⇒" )
    , ( "RightArrowLeftArrow", "⇄" )
    , ( "rightarrowtail", "↣" )
    , ( "RightCeiling", "⌉" )
    , ( "RightDoubleBracket", "⟧" )
    , ( "RightDownTeeVector", "⥝" )
    , ( "RightDownVectorBar", "⥕" )
    , ( "RightDownVector", "⇂" )
    , ( "RightFloor", "⌋" )
    , ( "rightharpoondown", "⇁" )
    , ( "rightharpoonup", "⇀" )
    , ( "rightleftarrows", "⇄" )
    , ( "rightleftharpoons", "⇌" )
    , ( "rightrightarrows", "⇉" )
    , ( "rightsquigarrow", "↝" )
    , ( "RightTeeArrow", "↦" )
    , ( "RightTee", "⊢" )
    , ( "RightTeeVector", "⥛" )
    , ( "rightthreetimes", "⋌" )
    , ( "RightTriangleBar", "⧐" )
    , ( "RightTriangle", "⊳" )
    , ( "RightTriangleEqual", "⊵" )
    , ( "RightUpDownVector", "⥏" )
    , ( "RightUpTeeVector", "⥜" )
    , ( "RightUpVectorBar", "⥔" )
    , ( "RightUpVector", "↾" )
    , ( "RightVectorBar", "⥓" )
    , ( "RightVector", "⇀" )
    , ( "ring", "˚" )
    , ( "risingdotseq", "≓" )
    , ( "rlarr", "⇄" )
    , ( "rlhar", "⇌" )
    , ( "rlm", "\u{200F}" )
    , ( "rmoustache", "⎱" )
    , ( "rmoust", "⎱" )
    , ( "rnmid", "⫮" )
    , ( "roang", "⟭" )
    , ( "roarr", "⇾" )
    , ( "robrk", "⟧" )
    , ( "ropar", "⦆" )
    , ( "ropf", "\u{D835}\u{DD63}" )
    , ( "Ropf", "ℝ" )
    , ( "roplus", "⨮" )
    , ( "rotimes", "⨵" )
    , ( "RoundImplies", "⥰" )
    , ( "rpar", ")" )
    , ( "rpargt", "⦔" )
    , ( "rppolint", "⨒" )
    , ( "rrarr", "⇉" )
    , ( "Rrightarrow", "⇛" )
    , ( "rsaquo", "›" )
    , ( "rscr", "\u{D835}\u{DCC7}" )
    , ( "Rscr", "ℛ" )
    , ( "rsh", "↱" )
    , ( "Rsh", "↱" )
    , ( "rsqb", "]" )
    , ( "rsquo", "’" )
    , ( "rsquor", "’" )
    , ( "rthree", "⋌" )
    , ( "rtimes", "⋊" )
    , ( "rtri", "▹" )
    , ( "rtrie", "⊵" )
    , ( "rtrif", "▸" )
    , ( "rtriltri", "⧎" )
    , ( "RuleDelayed", "⧴" )
    , ( "ruluhar", "⥨" )
    , ( "rx", "℞" )
    , ( "Sacute", "Ś" )
    , ( "sacute", "ś" )
    , ( "sbquo", "‚" )
    , ( "scap", "⪸" )
    , ( "Scaron", "Š" )
    , ( "scaron", "š" )
    , ( "Sc", "⪼" )
    , ( "sc", "≻" )
    , ( "sccue", "≽" )
    , ( "sce", "⪰" )
    , ( "scE", "⪴" )
    , ( "Scedil", "Ş" )
    , ( "scedil", "ş" )
    , ( "Scirc", "Ŝ" )
    , ( "scirc", "ŝ" )
    , ( "scnap", "⪺" )
    , ( "scnE", "⪶" )
    , ( "scnsim", "⋩" )
    , ( "scpolint", "⨓" )
    , ( "scsim", "≿" )
    , ( "Scy", "С" )
    , ( "scy", "с" )
    , ( "sdotb", "⊡" )
    , ( "sdot", "⋅" )
    , ( "sdote", "⩦" )
    , ( "searhk", "⤥" )
    , ( "searr", "↘" )
    , ( "seArr", "⇘" )
    , ( "searrow", "↘" )
    , ( "sect", "§" )
    , ( "semi", ";" )
    , ( "seswar", "⤩" )
    , ( "setminus", "∖" )
    , ( "setmn", "∖" )
    , ( "sext", "✶" )
    , ( "Sfr", "\u{D835}\u{DD16}" )
    , ( "sfr", "\u{D835}\u{DD30}" )
    , ( "sfrown", "⌢" )
    , ( "sharp", "♯" )
    , ( "SHCHcy", "Щ" )
    , ( "shchcy", "щ" )
    , ( "SHcy", "Ш" )
    , ( "shcy", "ш" )
    , ( "ShortDownArrow", "↓" )
    , ( "ShortLeftArrow", "←" )
    , ( "shortmid", "∣" )
    , ( "shortparallel", "∥" )
    , ( "ShortRightArrow", "→" )
    , ( "ShortUpArrow", "↑" )
    , ( "shy", "\u{00AD}" )
    , ( "Sigma", "Σ" )
    , ( "sigma", "σ" )
    , ( "sigmaf", "ς" )
    , ( "sigmav", "ς" )
    , ( "sim", "∼" )
    , ( "simdot", "⩪" )
    , ( "sime", "≃" )
    , ( "simeq", "≃" )
    , ( "simg", "⪞" )
    , ( "simgE", "⪠" )
    , ( "siml", "⪝" )
    , ( "simlE", "⪟" )
    , ( "simne", "≆" )
    , ( "simplus", "⨤" )
    , ( "simrarr", "⥲" )
    , ( "slarr", "←" )
    , ( "SmallCircle", "∘" )
    , ( "smallsetminus", "∖" )
    , ( "smashp", "⨳" )
    , ( "smeparsl", "⧤" )
    , ( "smid", "∣" )
    , ( "smile", "⌣" )
    , ( "smt", "⪪" )
    , ( "smte", "⪬" )
    , ( "smtes", "⪬︀" )
    , ( "SOFTcy", "Ь" )
    , ( "softcy", "ь" )
    , ( "solbar", "⌿" )
    , ( "solb", "⧄" )
    , ( "sol", "/" )
    , ( "Sopf", "\u{D835}\u{DD4A}" )
    , ( "sopf", "\u{D835}\u{DD64}" )
    , ( "spades", "♠" )
    , ( "spadesuit", "♠" )
    , ( "spar", "∥" )
    , ( "sqcap", "⊓" )
    , ( "sqcaps", "⊓︀" )
    , ( "sqcup", "⊔" )
    , ( "sqcups", "⊔︀" )
    , ( "Sqrt", "√" )
    , ( "sqsub", "⊏" )
    , ( "sqsube", "⊑" )
    , ( "sqsubset", "⊏" )
    , ( "sqsubseteq", "⊑" )
    , ( "sqsup", "⊐" )
    , ( "sqsupe", "⊒" )
    , ( "sqsupset", "⊐" )
    , ( "sqsupseteq", "⊒" )
    , ( "square", "□" )
    , ( "Square", "□" )
    , ( "SquareIntersection", "⊓" )
    , ( "SquareSubset", "⊏" )
    , ( "SquareSubsetEqual", "⊑" )
    , ( "SquareSuperset", "⊐" )
    , ( "SquareSupersetEqual", "⊒" )
    , ( "SquareUnion", "⊔" )
    , ( "squarf", "▪" )
    , ( "squ", "□" )
    , ( "squf", "▪" )
    , ( "srarr", "→" )
    , ( "Sscr", "\u{D835}\u{DCAE}" )
    , ( "sscr", "\u{D835}\u{DCC8}" )
    , ( "ssetmn", "∖" )
    , ( "ssmile", "⌣" )
    , ( "sstarf", "⋆" )
    , ( "Star", "⋆" )
    , ( "star", "☆" )
    , ( "starf", "★" )
    , ( "straightepsilon", "ϵ" )
    , ( "straightphi", "ϕ" )
    , ( "strns", "¯" )
    , ( "sub", "⊂" )
    , ( "Sub", "⋐" )
    , ( "subdot", "⪽" )
    , ( "subE", "⫅" )
    , ( "sube", "⊆" )
    , ( "subedot", "⫃" )
    , ( "submult", "⫁" )
    , ( "subnE", "⫋" )
    , ( "subne", "⊊" )
    , ( "subplus", "⪿" )
    , ( "subrarr", "⥹" )
    , ( "subset", "⊂" )
    , ( "Subset", "⋐" )
    , ( "subseteq", "⊆" )
    , ( "subseteqq", "⫅" )
    , ( "SubsetEqual", "⊆" )
    , ( "subsetneq", "⊊" )
    , ( "subsetneqq", "⫋" )
    , ( "subsim", "⫇" )
    , ( "subsub", "⫕" )
    , ( "subsup", "⫓" )
    , ( "succapprox", "⪸" )
    , ( "succ", "≻" )
    , ( "succcurlyeq", "≽" )
    , ( "Succeeds", "≻" )
    , ( "SucceedsEqual", "⪰" )
    , ( "SucceedsSlantEqual", "≽" )
    , ( "SucceedsTilde", "≿" )
    , ( "succeq", "⪰" )
    , ( "succnapprox", "⪺" )
    , ( "succneqq", "⪶" )
    , ( "succnsim", "⋩" )
    , ( "succsim", "≿" )
    , ( "SuchThat", "∋" )
    , ( "sum", "∑" )
    , ( "Sum", "∑" )
    , ( "sung", "♪" )
    , ( "sup1", "¹" )
    , ( "sup2", "²" )
    , ( "sup3", "³" )
    , ( "sup", "⊃" )
    , ( "Sup", "⋑" )
    , ( "supdot", "⪾" )
    , ( "supdsub", "⫘" )
    , ( "supE", "⫆" )
    , ( "supe", "⊇" )
    , ( "supedot", "⫄" )
    , ( "Superset", "⊃" )
    , ( "SupersetEqual", "⊇" )
    , ( "suphsol", "⟉" )
    , ( "suphsub", "⫗" )
    , ( "suplarr", "⥻" )
    , ( "supmult", "⫂" )
    , ( "supnE", "⫌" )
    , ( "supne", "⊋" )
    , ( "supplus", "⫀" )
    , ( "supset", "⊃" )
    , ( "Supset", "⋑" )
    , ( "supseteq", "⊇" )
    , ( "supseteqq", "⫆" )
    , ( "supsetneq", "⊋" )
    , ( "supsetneqq", "⫌" )
    , ( "supsim", "⫈" )
    , ( "supsub", "⫔" )
    , ( "supsup", "⫖" )
    , ( "swarhk", "⤦" )
    , ( "swarr", "↙" )
    , ( "swArr", "⇙" )
    , ( "swarrow", "↙" )
    , ( "swnwar", "⤪" )
    , ( "szlig", "ß" )
    , ( "Tab", "\t" )
    , ( "target", "⌖" )
    , ( "Tau", "Τ" )
    , ( "tau", "τ" )
    , ( "tbrk", "⎴" )
    , ( "Tcaron", "Ť" )
    , ( "tcaron", "ť" )
    , ( "Tcedil", "Ţ" )
    , ( "tcedil", "ţ" )
    , ( "Tcy", "Т" )
    , ( "tcy", "т" )
    , ( "tdot", "⃛" )
    , ( "telrec", "⌕" )
    , ( "Tfr", "\u{D835}\u{DD17}" )
    , ( "tfr", "\u{D835}\u{DD31}" )
    , ( "there4", "∴" )
    , ( "therefore", "∴" )
    , ( "Therefore", "∴" )
    , ( "Theta", "Θ" )
    , ( "theta", "θ" )
    , ( "thetasym", "ϑ" )
    , ( "thetav", "ϑ" )
    , ( "thickapprox", "≈" )
    , ( "thicksim", "∼" )
    , ( "ThickSpace", "\u{205F}\u{200A}" )
    , ( "ThinSpace", "\u{2009}" )
    , ( "thinsp", "\u{2009}" )
    , ( "thkap", "≈" )
    , ( "thksim", "∼" )
    , ( "THORN", "Þ" )
    , ( "thorn", "þ" )
    , ( "tilde", "˜" )
    , ( "Tilde", "∼" )
    , ( "TildeEqual", "≃" )
    , ( "TildeFullEqual", "≅" )
    , ( "TildeTilde", "≈" )
    , ( "timesbar", "⨱" )
    , ( "timesb", "⊠" )
    , ( "times", "×" )
    , ( "timesd", "⨰" )
    , ( "tint", "∭" )
    , ( "toea", "⤨" )
    , ( "topbot", "⌶" )
    , ( "topcir", "⫱" )
    , ( "top", "⊤" )
    , ( "Topf", "\u{D835}\u{DD4B}" )
    , ( "topf", "\u{D835}\u{DD65}" )
    , ( "topfork", "⫚" )
    , ( "tosa", "⤩" )
    , ( "tprime", "‴" )
    , ( "trade", "™" )
    , ( "TRADE", "™" )
    , ( "triangle", "▵" )
    , ( "triangledown", "▿" )
    , ( "triangleleft", "◃" )
    , ( "trianglelefteq", "⊴" )
    , ( "triangleq", "≜" )
    , ( "triangleright", "▹" )
    , ( "trianglerighteq", "⊵" )
    , ( "tridot", "◬" )
    , ( "trie", "≜" )
    , ( "triminus", "⨺" )
    , ( "TripleDot", "⃛" )
    , ( "triplus", "⨹" )
    , ( "trisb", "⧍" )
    , ( "tritime", "⨻" )
    , ( "trpezium", "⏢" )
    , ( "Tscr", "\u{D835}\u{DCAF}" )
    , ( "tscr", "\u{D835}\u{DCC9}" )
    , ( "TScy", "Ц" )
    , ( "tscy", "ц" )
    , ( "TSHcy", "Ћ" )
    , ( "tshcy", "ћ" )
    , ( "Tstrok", "Ŧ" )
    , ( "tstrok", "ŧ" )
    , ( "twixt", "≬" )
    , ( "twoheadleftarrow", "↞" )
    , ( "twoheadrightarrow", "↠" )
    , ( "Uacute", "Ú" )
    , ( "uacute", "ú" )
    , ( "uarr", "↑" )
    , ( "Uarr", "↟" )
    , ( "uArr", "⇑" )
    , ( "Uarrocir", "⥉" )
    , ( "Ubrcy", "Ў" )
    , ( "ubrcy", "ў" )
    , ( "Ubreve", "Ŭ" )
    , ( "ubreve", "ŭ" )
    , ( "Ucirc", "Û" )
    , ( "ucirc", "û" )
    , ( "Ucy", "У" )
    , ( "ucy", "у" )
    , ( "udarr", "⇅" )
    , ( "Udblac", "Ű" )
    , ( "udblac", "ű" )
    , ( "udhar", "⥮" )
    , ( "ufisht", "⥾" )
    , ( "Ufr", "\u{D835}\u{DD18}" )
    , ( "ufr", "\u{D835}\u{DD32}" )
    , ( "Ugrave", "Ù" )
    , ( "ugrave", "ù" )
    , ( "uHar", "⥣" )
    , ( "uharl", "↿" )
    , ( "uharr", "↾" )
    , ( "uhblk", "▀" )
    , ( "ulcorn", "⌜" )
    , ( "ulcorner", "⌜" )
    , ( "ulcrop", "⌏" )
    , ( "ultri", "◸" )
    , ( "Umacr", "Ū" )
    , ( "umacr", "ū" )
    , ( "uml", "¨" )
    , ( "UnderBar", "_" )
    , ( "UnderBrace", "⏟" )
    , ( "UnderBracket", "⎵" )
    , ( "UnderParenthesis", "⏝" )
    , ( "Union", "⋃" )
    , ( "UnionPlus", "⊎" )
    , ( "Uogon", "Ų" )
    , ( "uogon", "ų" )
    , ( "Uopf", "\u{D835}\u{DD4C}" )
    , ( "uopf", "\u{D835}\u{DD66}" )
    , ( "UpArrowBar", "⤒" )
    , ( "uparrow", "↑" )
    , ( "UpArrow", "↑" )
    , ( "Uparrow", "⇑" )
    , ( "UpArrowDownArrow", "⇅" )
    , ( "updownarrow", "↕" )
    , ( "UpDownArrow", "↕" )
    , ( "Updownarrow", "⇕" )
    , ( "UpEquilibrium", "⥮" )
    , ( "upharpoonleft", "↿" )
    , ( "upharpoonright", "↾" )
    , ( "uplus", "⊎" )
    , ( "UpperLeftArrow", "↖" )
    , ( "UpperRightArrow", "↗" )
    , ( "upsi", "υ" )
    , ( "Upsi", "ϒ" )
    , ( "upsih", "ϒ" )
    , ( "Upsilon", "Υ" )
    , ( "upsilon", "υ" )
    , ( "UpTeeArrow", "↥" )
    , ( "UpTee", "⊥" )
    , ( "upuparrows", "⇈" )
    , ( "urcorn", "⌝" )
    , ( "urcorner", "⌝" )
    , ( "urcrop", "⌎" )
    , ( "Uring", "Ů" )
    , ( "uring", "ů" )
    , ( "urtri", "◹" )
    , ( "Uscr", "\u{D835}\u{DCB0}" )
    , ( "uscr", "\u{D835}\u{DCCA}" )
    , ( "utdot", "⋰" )
    , ( "Utilde", "Ũ" )
    , ( "utilde", "ũ" )
    , ( "utri", "▵" )
    , ( "utrif", "▴" )
    , ( "uuarr", "⇈" )
    , ( "Uuml", "Ü" )
    , ( "uuml", "ü" )
    , ( "uwangle", "⦧" )
    , ( "vangrt", "⦜" )
    , ( "varepsilon", "ϵ" )
    , ( "varkappa", "ϰ" )
    , ( "varnothing", "∅" )
    , ( "varphi", "ϕ" )
    , ( "varpi", "ϖ" )
    , ( "varpropto", "∝" )
    , ( "varr", "↕" )
    , ( "vArr", "⇕" )
    , ( "varrho", "ϱ" )
    , ( "varsigma", "ς" )
    , ( "varsubsetneq", "⊊︀" )
    , ( "varsubsetneqq", "⫋︀" )
    , ( "varsupsetneq", "⊋︀" )
    , ( "varsupsetneqq", "⫌︀" )
    , ( "vartheta", "ϑ" )
    , ( "vartriangleleft", "⊲" )
    , ( "vartriangleright", "⊳" )
    , ( "vBar", "⫨" )
    , ( "Vbar", "⫫" )
    , ( "vBarv", "⫩" )
    , ( "Vcy", "В" )
    , ( "vcy", "в" )
    , ( "vdash", "⊢" )
    , ( "vDash", "⊨" )
    , ( "Vdash", "⊩" )
    , ( "VDash", "⊫" )
    , ( "Vdashl", "⫦" )
    , ( "veebar", "⊻" )
    , ( "vee", "∨" )
    , ( "Vee", "⋁" )
    , ( "veeeq", "≚" )
    , ( "vellip", "⋮" )
    , ( "verbar", "|" )
    , ( "Verbar", "‖" )
    , ( "vert", "|" )
    , ( "Vert", "‖" )
    , ( "VerticalBar", "∣" )
    , ( "VerticalLine", "|" )
    , ( "VerticalSeparator", "❘" )
    , ( "VerticalTilde", "≀" )
    , ( "VeryThinSpace", "\u{200A}" )
    , ( "Vfr", "\u{D835}\u{DD19}" )
    , ( "vfr", "\u{D835}\u{DD33}" )
    , ( "vltri", "⊲" )
    , ( "vnsub", "⊂⃒" )
    , ( "vnsup", "⊃⃒" )
    , ( "Vopf", "\u{D835}\u{DD4D}" )
    , ( "vopf", "\u{D835}\u{DD67}" )
    , ( "vprop", "∝" )
    , ( "vrtri", "⊳" )
    , ( "Vscr", "\u{D835}\u{DCB1}" )
    , ( "vscr", "\u{D835}\u{DCCB}" )
    , ( "vsubnE", "⫋︀" )
    , ( "vsubne", "⊊︀" )
    , ( "vsupnE", "⫌︀" )
    , ( "vsupne", "⊋︀" )
    , ( "Vvdash", "⊪" )
    , ( "vzigzag", "⦚" )
    , ( "Wcirc", "Ŵ" )
    , ( "wcirc", "ŵ" )
    , ( "wedbar", "⩟" )
    , ( "wedge", "∧" )
    , ( "Wedge", "⋀" )
    , ( "wedgeq", "≙" )
    , ( "weierp", "℘" )
    , ( "Wfr", "\u{D835}\u{DD1A}" )
    , ( "wfr", "\u{D835}\u{DD34}" )
    , ( "Wopf", "\u{D835}\u{DD4E}" )
    , ( "wopf", "\u{D835}\u{DD68}" )
    , ( "wp", "℘" )
    , ( "wr", "≀" )
    , ( "wreath", "≀" )
    , ( "Wscr", "\u{D835}\u{DCB2}" )
    , ( "wscr", "\u{D835}\u{DCCC}" )
    , ( "xcap", "⋂" )
    , ( "xcirc", "◯" )
    , ( "xcup", "⋃" )
    , ( "xdtri", "▽" )
    , ( "Xfr", "\u{D835}\u{DD1B}" )
    , ( "xfr", "\u{D835}\u{DD35}" )
    , ( "xharr", "⟷" )
    , ( "xhArr", "⟺" )
    , ( "Xi", "Ξ" )
    , ( "xi", "ξ" )
    , ( "xlarr", "⟵" )
    , ( "xlArr", "⟸" )
    , ( "xmap", "⟼" )
    , ( "xnis", "⋻" )
    , ( "xodot", "⨀" )
    , ( "Xopf", "\u{D835}\u{DD4F}" )
    , ( "xopf", "\u{D835}\u{DD69}" )
    , ( "xoplus", "⨁" )
    , ( "xotime", "⨂" )
    , ( "xrarr", "⟶" )
    , ( "xrArr", "⟹" )
    , ( "Xscr", "\u{D835}\u{DCB3}" )
    , ( "xscr", "\u{D835}\u{DCCD}" )
    , ( "xsqcup", "⨆" )
    , ( "xuplus", "⨄" )
    , ( "xutri", "△" )
    , ( "xvee", "⋁" )
    , ( "xwedge", "⋀" )
    , ( "Yacute", "Ý" )
    , ( "yacute", "ý" )
    , ( "YAcy", "Я" )
    , ( "yacy", "я" )
    , ( "Ycirc", "Ŷ" )
    , ( "ycirc", "ŷ" )
    , ( "Ycy", "Ы" )
    , ( "ycy", "ы" )
    , ( "yen", "¥" )
    , ( "Yfr", "\u{D835}\u{DD1C}" )
    , ( "yfr", "\u{D835}\u{DD36}" )
    , ( "YIcy", "Ї" )
    , ( "yicy", "ї" )
    , ( "Yopf", "\u{D835}\u{DD50}" )
    , ( "yopf", "\u{D835}\u{DD6A}" )
    , ( "Yscr", "\u{D835}\u{DCB4}" )
    , ( "yscr", "\u{D835}\u{DCCE}" )
    , ( "YUcy", "Ю" )
    , ( "yucy", "ю" )
    , ( "yuml", "ÿ" )
    , ( "Yuml", "Ÿ" )
    , ( "Zacute", "Ź" )
    , ( "zacute", "ź" )
    , ( "Zcaron", "Ž" )
    , ( "zcaron", "ž" )
    , ( "Zcy", "З" )
    , ( "zcy", "з" )
    , ( "Zdot", "Ż" )
    , ( "zdot", "ż" )
    , ( "zeetrf", "ℨ" )
    , ( "ZeroWidthSpace", "\u{200B}" )
    , ( "Zeta", "Ζ" )
    , ( "zeta", "ζ" )
    , ( "zfr", "\u{D835}\u{DD37}" )
    , ( "Zfr", "ℨ" )
    , ( "ZHcy", "Ж" )
    , ( "zhcy", "ж" )
    , ( "zigrarr", "⇝" )
    , ( "zopf", "\u{D835}\u{DD6B}" )
    , ( "Zopf", "ℤ" )
    , ( "Zscr", "\u{D835}\u{DCB5}" )
    , ( "zscr", "\u{D835}\u{DCCF}" )
    , ( "zwj", "\u{200D}" )
    , ( "zwnj", "\u{200C}" )
    ]
        |> Dict.fromList
