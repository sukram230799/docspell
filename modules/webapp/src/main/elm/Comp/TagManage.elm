module Comp.TagManage exposing ( Model
                               , emptyModel
                               , Msg(..)
                               , view
                               , update)

import Http
import Api
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (onClick, onSubmit)
import Data.Flags exposing (Flags)
import Comp.TagTable
import Comp.TagForm
import Comp.YesNoDimmer
import Api.Model.Tag
import Api.Model.TagList exposing (TagList)
import Api.Model.BasicResult exposing (BasicResult)
import Util.Maybe
import Util.Http

type alias Model =
    { tagTableModel: Comp.TagTable.Model
    , tagFormModel: Comp.TagForm.Model
    , viewMode: ViewMode
    , formError: Maybe String
    , loading: Bool
    , deleteConfirm: Comp.YesNoDimmer.Model
    }

type ViewMode = Table | Form

emptyModel: Model
emptyModel =
    { tagTableModel = Comp.TagTable.emptyModel
    , tagFormModel = Comp.TagForm.emptyModel
    , viewMode = Table
    , formError = Nothing
    , loading = False
    , deleteConfirm = Comp.YesNoDimmer.emptyModel
    }

type Msg
    = TableMsg Comp.TagTable.Msg
    | FormMsg Comp.TagForm.Msg
    | LoadTags
    | TagResp (Result Http.Error TagList)
    | SetViewMode ViewMode
    | InitNewTag
    | Submit
    | SubmitResp (Result Http.Error BasicResult)
    | YesNoMsg Comp.YesNoDimmer.Msg
    | RequestDelete

update: Flags -> Msg -> Model -> (Model, Cmd Msg)
update flags msg model =
    case msg of
        TableMsg m ->
            let
                (tm, tc) = Comp.TagTable.update flags m model.tagTableModel
                (m2, c2) = ({model | tagTableModel = tm
                            , viewMode = Maybe.map (\_ -> Form) tm.selected |> Maybe.withDefault Table
                            , formError = if Util.Maybe.nonEmpty tm.selected then Nothing else model.formError
                            }
                           , Cmd.map TableMsg tc
                           )
                (m3, c3) = case tm.selected of
                        Just tag ->
                            update flags (FormMsg (Comp.TagForm.SetTag tag)) m2
                        Nothing ->
                            (m2, Cmd.none)
            in
                (m3, Cmd.batch [c2, c3])

        FormMsg m ->
            let
                (m2, c2) = Comp.TagForm.update flags m model.tagFormModel
            in
                ({model | tagFormModel = m2}, Cmd.map FormMsg c2)

        LoadTags ->
            ({model| loading = True}, Api.getTags flags TagResp)

        TagResp (Ok tags) ->
            let
                m2 = {model|viewMode = Table, loading = False}
            in
                update flags (TableMsg (Comp.TagTable.SetTags tags.items)) m2

        TagResp (Err err) ->
            ({model|loading = False}, Cmd.none)

        SetViewMode m ->
            let
                m2 = {model | viewMode = m }
            in
                case m of
                    Table ->
                        update flags (TableMsg Comp.TagTable.Deselect) m2
                    Form ->
                        (m2, Cmd.none)

        InitNewTag ->
            let
                nm = {model | viewMode = Form, formError = Nothing }
                tag = Api.Model.Tag.empty
            in
                update flags (FormMsg (Comp.TagForm.SetTag tag)) nm

        Submit ->
            let
                tag = Comp.TagForm.getTag model.tagFormModel
                valid = Comp.TagForm.isValid model.tagFormModel
            in if valid then
                   ({model|loading = True}, Api.postTag flags tag SubmitResp)
               else
                   ({model|formError = Just "Please correct the errors in the form."}, Cmd.none)

        SubmitResp (Ok res) ->
            if res.success then
                let
                    (m2, c2) = update flags (SetViewMode Table) model
                    (m3, c3) = update flags LoadTags m2
                in
                    ({m3|loading = False}, Cmd.batch [c2,c3])
            else
                ({model | formError = Just res.message, loading = False }, Cmd.none)

        SubmitResp (Err err) ->
            ({model | formError = Just (Util.Http.errorToString err), loading = False}, Cmd.none)

        RequestDelete ->
            update flags (YesNoMsg Comp.YesNoDimmer.activate) model

        YesNoMsg m ->
            let
                (cm, confirmed) = Comp.YesNoDimmer.update m model.deleteConfirm
                tag = Comp.TagForm.getTag model.tagFormModel
                cmd = if confirmed then Api.deleteTag flags tag.id SubmitResp else Cmd.none
            in
                ({model | deleteConfirm = cm}, cmd)

view: Model -> Html Msg
view model =
    if model.viewMode == Table then viewTable model
    else viewForm model

viewTable: Model -> Html Msg
viewTable model =
    div []
        [button [class "ui basic button", onClick InitNewTag]
             [i [class "plus icon"][]
             ,text "Create new"
             ]
        ,Html.map TableMsg (Comp.TagTable.view model.tagTableModel)
        ,div [classList [("ui dimmer", True)
                        ,("active", model.loading)
                        ]]
            [div [class "ui loader"][]
            ]
        ]

viewForm: Model -> Html Msg
viewForm model =
    let
        newTag = model.tagFormModel.tag.id == ""
    in
        Html.form [class "ui segment", onSubmit Submit]
            [Html.map YesNoMsg (Comp.YesNoDimmer.view model.deleteConfirm)
            ,if newTag then
                 h3 [class "ui dividing header"]
                    [text "Create new tag"
                    ]
             else
                 h3 [class "ui dividing header"]
                    [text ("Edit tag: " ++ model.tagFormModel.tag.name)
                    ,div [class "sub header"]
                         [text "Id: "
                         ,text model.tagFormModel.tag.id
                         ]
                    ]
            ,Html.map FormMsg (Comp.TagForm.view model.tagFormModel)
            ,div [classList [("ui error message", True)
                            ,("invisible", Util.Maybe.isEmpty model.formError)
                            ]
                 ]
                 [Maybe.withDefault "" model.formError |> text
                 ]
            ,div [class "ui horizontal divider"][]
            ,button [class "ui primary button", type_ "submit"]
                [text "Submit"
                ]
            ,a [class "ui secondary button", onClick (SetViewMode Table), href ""]
                [text "Cancel"
                ]
            ,if not newTag then
                 a [class "ui right floated red button", href "", onClick RequestDelete]
                     [text "Delete"]
             else
                 span[][]
            ,div [classList [("ui dimmer", True)
                            ,("active", model.loading)
                            ]]
                 [div [class "ui loader"][]
                 ]
            ]