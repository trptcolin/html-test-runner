module Test.Runner.Html exposing (TestProgram, run, runWithOptions)

{-| HTML Runner

Runs tests in a browser and reports the results in the DOM. You can bring up
one of these tests in elm-reactor to have it run and show outputs.

@docs run, runWithOptions, TestProgram

-}

import Dict exposing (Dict)
import Set
import Time exposing (Time)
import Task
import Tuple
import Html exposing (Html)
import Random.Pcg as Random
import Test exposing (Test)
import Test.Runner exposing (Runner(..))
import Test.Runner.Html.View as View
import Expect exposing (Expectation)


type Msg
    = Start Time
    | Dispatch
    | Finish Time


type Model
    = NotStarted (Maybe Random.Seed) Int Test
    | Started View.Model


{-| A program which will run tests and report their results.
-}
type alias TestProgram =
    Program Never Model Msg


warn : String -> a -> a
warn =
    Debug.log


{-| Dispatch as a Cmd so as to yield to the UI
    thread in between test executions.
-}
dispatch : Cmd Msg
dispatch =
    Task.succeed Dispatch
        |> Task.perform identity


start : Time -> List (() -> ( List String, List Expectation )) -> ( Model, Cmd Msg )
start startTime thunks =
    let
        indexedThunks : List ( Int, () -> ( List String, List Expectation ) )
        indexedThunks =
            List.indexedMap (,) thunks

        model =
            { available = Dict.fromList indexedThunks
            , running = Set.empty
            , queue = List.map Tuple.first indexedThunks
            , completed = []
            , startTime = startTime
            , finishTime = Nothing
            }
    in
        ( Started model, dispatch )


{-| Run the test and report the results.

Fuzz tests use a default run count of 100, and an initial seed based on the
system time when the test runs begin.
-}
run : Test -> TestProgram
run =
    runWithOptions Nothing Nothing


{-| Run the test using the provided options. If `Nothing` is provided for either
`runs` or `seed`, it will fall back on the options used in [`run`](#run).
-}
runWithOptions : Maybe Int -> Maybe Random.Seed -> Test -> TestProgram
runWithOptions maybeRuns seed test =
    let
        runs =
            Maybe.withDefault defaultRunCount maybeRuns

        getTime =
            Task.perform Start Time.now
    in
        Html.program
            { init = ( NotStarted seed runs test, getTime )
            , update = update
            , view = view
            , subscriptions = \_ -> Sub.none
            }


timeToSeed : Time -> Random.Seed
timeToSeed time =
    (0xFFFFFFFF * time)
        |> floor
        |> Random.initialSeed


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case ( msg, model ) of
        ( Start time, NotStarted seed runs test ) ->
            let
                finalSeed =
                    case seed of
                        Just realSeed ->
                            realSeed

                        Nothing ->
                            timeToSeed time
            in
                test
                    |> Test.Runner.fromTest runs finalSeed
                    |> toThunks []
                    |> start time

        ( Finish time, Started viewModel ) ->
            case viewModel.finishTime of
                Nothing ->
                    ( Started { viewModel | finishTime = Just time }, Cmd.none )

                Just _ ->
                    ( Started viewModel, Cmd.none )
                        |> warn "Attempted to Finish more than once!"

        ( Dispatch, Started viewModel ) ->
            case viewModel.queue of
                [] ->
                    ( Started viewModel, Task.perform Finish Time.now )

                testId :: newQueue ->
                    case Dict.get testId viewModel.available of
                        Nothing ->
                            ( Started viewModel, Cmd.none )
                                |> warn ("Could not find testId " ++ toString testId)

                        Just run ->
                            let
                                completed =
                                    viewModel.completed ++ [ run () ]

                                available =
                                    Dict.remove testId viewModel.available

                                newModel =
                                    { viewModel
                                        | completed = completed
                                        , available = available
                                        , queue = newQueue
                                    }
                            in
                                ( Started newModel, dispatch )

        ( Start _, Started _ ) ->
            Debug.crash "Attempted to start twice!"

        ( _, NotStarted _ _ _ ) ->
            Debug.crash "Attempted to run a Msg pre-Start!"


view : Model -> Html Msg
view model =
    case model of
        NotStarted _ _ _ ->
            View.notStarted

        Started viewModel ->
            View.started viewModel


toThunks : List String -> Runner -> List (() -> ( List String, List Expectation ))
toThunks labels runner =
    case runner of
        Runnable runnable ->
            [ \() -> ( labels, Test.Runner.run runnable ) ]

        Labeled label subRunner ->
            toThunks (label :: labels) subRunner

        Batch runners ->
            List.concatMap (toThunks labels) runners


defaultRunCount : Int
defaultRunCount =
    100
