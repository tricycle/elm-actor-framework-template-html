module Framework.Template.Html.Internal.Render exposing (render, renderAndInterpolate)

import Dict exposing (Dict)
import Framework.Actor exposing (Pid)
import Framework.Template exposing (ActorElement(..), Node(..))
import Framework.Template.Html.Internal.HtmlTemplate as HtmlTemplate exposing (HtmlTemplate)
import Html exposing (Html)
import Html.Attributes as HtmlA
import Regex exposing (Match, Regex)


render :
    Dict String Pid
    -> (Pid -> Maybe (Html msg))
    -> HtmlTemplate appActors
    -> List (Html msg)
render instances renderPid htmlTemplate =
    renderAndInterpolate instances Dict.empty renderPid htmlTemplate


renderAndInterpolate :
    Dict String Pid
    -> Dict String String
    -> (Pid -> Maybe (Html msg))
    -> HtmlTemplate appActors
    -> List (Html msg)
renderAndInterpolate instances interpolateData renderPid htmlTemplate =
    let
        nodes =
            HtmlTemplate.toNodes htmlTemplate
    in
    templateNodesToListHtml
        (makeRenderReference instances renderPid)
        (interpolateWithDict interpolateData)
        nodes


makeRenderReference :
    Dict String Pid
    -> (Pid -> Maybe (Html msg))
    -> String
    -> Maybe (Html msg)
makeRenderReference instances renderPid reference =
    Dict.get reference instances
        |> Maybe.andThen renderPid


templateNodesToListHtml :
    (String -> Maybe (Html msg))
    -> (String -> String)
    -> List (Node appActors)
    -> List (Html msg)
templateNodesToListHtml renderReference interpolator =
    List.map (templateNodeToHtml renderReference interpolator)


templateNodeToHtml :
    (String -> Maybe (Html msg))
    -> (String -> String)
    -> Node appActors
    -> Html msg
templateNodeToHtml renderReference interpolator node =
    case node of
        Text string ->
            Html.text (interpolator string)

        Element nodeName attributes children ->
            Html.node
                nodeName
                (toHtmlAttributes interpolator attributes)
                (templateNodesToListHtml renderReference interpolator children)

        Actor (ActorElement _ nodeName id _ children) ->
            case renderReference id of
                Just output ->
                    output

                Nothing ->
                    let
                        htmlAttributes =
                            [ ( "data-x-name", nodeName )
                            , ( "data-x-id", id )
                            ]
                                |> toHtmlAttributes interpolator
                    in
                    Html.node
                        nodeName
                        htmlAttributes
                        (templateNodesToListHtml renderReference interpolator children)


toHtmlAttributes :
    (String -> String)
    -> List ( String, String )
    -> List (Html.Attribute msg)
toHtmlAttributes interpolator =
    List.map
        (\( key, value ) ->
            let
                interpolatedValue =
                    interpolator value
            in
            case String.toLower key of
                "class" ->
                    HtmlA.class interpolatedValue

                _ ->
                    HtmlA.attribute key interpolatedValue
        )



--- Interpolate


interpolateWithDict : Dict String String -> String -> String
interpolateWithDict dict string =
    Regex.replace
        dictInterpolationRegex
        (applyDictInterpolation dict)
        string


dictInterpolationRegex : Regex
dictInterpolationRegex =
    Regex.fromString "#\\[[\\w.-]+\\]"
        |> Maybe.withDefault Regex.never


applyDictInterpolation : Dict String String -> Match -> String
applyDictInterpolation replacements { match } =
    let
        ordinalString =
            (String.dropLeft 2 << String.dropRight 1) match
    in
    Dict.get ordinalString replacements
        |> Maybe.withDefault ordinalString
