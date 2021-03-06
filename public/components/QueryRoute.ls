ace-language-tools = require \brace/ext/language_tools 
require! \../client-storage.ls
config = require \../../config.ls
window.d3 = require \d3
$ = require \jquery-browserify
{key} = require \keymaster
require! \notifyjs

# prelude
{all, any, camelize, concat-map, dasherize, difference, each, filter, find, keys, is-type, last, map, 
sort, sort-by, sum, round, obj-to-pairs, pairs-to-obj, reject, take, unique, unique-by, Obj} = require \prelude-ls

{is-equal-to-object} = require \prelude-extension

# utils
{cancel-event, get-all-keys-recursively} = require \../utils.ls

_ = require \underscore
{create-factory, DOM:{a, div, input, label, span, select, option, button, script}}:React = require \react
{find-DOM-node}:ReactDOM = require \react-dom
{History}:react-router = require \react-router
Link = create-factory react-router.Link
AceEditor = create-factory require \./AceEditor.ls
ConflictDialog = create-factory require \./ConflictDialog.ls
DataSourceCuePopup = create-factory require \./DataSourceCuePopup.ls
Menu = create-factory require \./Menu.ls
MultiSelect = create-factory (require \react-selectize).MultiSelect
NewQueryDialog = create-factory (require \./NewQueryDialog.ls)
SettingsDialog = create-factory require \./SettingsDialog.ls
SharePopup = create-factory require \./SharePopup.ls
ui-protocol =
    mongodb: require \../query-types/mongodb/ui-protocol.ls
    mssql: require \../query-types/mssql/ui-protocol.ls
    multi: require \../query-types/multi/ui-protocol.ls
    curl: require \../query-types/curl/ui-protocol.ls
    postgresql: require \../query-types/postgresql/ui-protocol.ls
    mysql: require \../query-types/mysql/ui-protocol.ls
    redis: require \../query-types/redis/ui-protocol.ls
    elastic: require \../query-types/elastic/ui-protocol.ls
    sharepoint: require \../query-types/sharepoint/ui-protocol.ls
{compile-parameters, compile-transformation, compile-presentation, generate-uid}:pipe-web-client = 
    (require \pipe-web-client) end-point: "http://#{window.location.host}"

alphabet = [String.from-char-code i for i in [65 to 65+25] ++ [97 to 97+25]]

# TODO: move it to utils
# takes a collection of keyscores & maps them to {name, value, score, meta}
# [{keywords: [String], score: Int}] -> String -> String -> [{name, value, score, meta}]
convert-to-ace-keywords = (keyscores, meta, prefix) ->
    keyscores |> concat-map ({keywords, score}) -> 
        keywords 
        |> filter (-> if !prefix then true else  (it.index-of prefix) == 0)
        |> map (text) ->
            name: text
            value: text
            meta: meta
            score: score

# returns dasherized collection of keywords for auto-completion
keywords-from-object = (object) ->
    object
        |> keys 
        |> map dasherize

# returns a hash of editor-heights used in get-initial-state and state-from-document
# editor-heights :: Integer?, Integer?, Integer? -> {query-editor-height, transformation-editor-height, presentation-editor-height}
editor-heights = (query-editor-height = 300, transformation-editor-height = 324, presentation-editor-height = 240) ->
    # 50 = height of .menu defined in Meny.styl; 30 = height of .editor-title;
    viewport-height = window.inner-height - 50 - 3 * 30
    editor-heights = [query-editor-height, transformation-editor-height, presentation-editor-height] |> (ds) ->
        s = sum ds
        ds |> map round . (viewport-height *) . (/s)
    query-editor-height: editor-heights.0
    transformation-editor-height: editor-heights.1
    presentation-editor-height: editor-heights.2

# gracefully degrades if blocked by a popup blocker
# open-window :: URL -> Void
open-window = (url, target) !->
    if !window.open url, target
        alert "PLEASE DISABLE THE POPUP BLOCKER \n\nUNABLE TO OPEN: #{url}"

# to-callback :: p a -> (a -> b) -> Void
to-callback = (promise, callback) !->
    promise.then (result) -> callback null, result
    promise.catch (err) -> callback err, null

module.exports = React.create-class do

    display-name: \QueryRoute

    # History mixin provides replace-state method which is used to update the url when the user saves the query
    # Lifecycle mixin provides route-will-leave method which helps in preventing the user from loosing his work
    mixins: [History]

    # React class method
    # get-default-props :: a -> Props
    get-default-props: ->
        auto-execute: false
        prevent-reload: true

    # React class method
    # render :: a -> VirtualDOM
    render: ->
        {
            query-id, branch-id, tree-id, transpilation-language, data-source-cue, query, 
            query-title, transformation, presentation, parameters, existing-tags, tags, 
            editor-width, popup-left, popup, queries-in-between, dialog, remote-document, 
            cache, from-cache, executing-op, displayed-on, execution-error, execution-end-time, 
            execution-duration, transpilation-language
        } = @state

        document.title = query-title

        # MENU ITEMS
        
        # toggle-popup :: String -> Number -> Number -> Void
        toggle-popup = (popup, button-left, button-width) !~~>
            @set-state do
                popup-left: button-left + button-width / 2
                popup: if @state.popup == popup then '' else popup

        saved-query = !!@props.params.branch-id and !(@props.params.branch-id in <[local localFork]>) and !!@props.params.query-id

        # MenuItem :: {label :: String, enabled :: Boolean, highlight :: Boolean, type :: String, hotkey :: String, pressed :: Boolean, action :: a -> Void}
        # menu-items :: [MenuItem]
        menu-items = 

            * label: \New
              href: \/branches
              action: ~> open-window "/branches", \_blank

            * label: \Fork
              enabled: saved-query
              action: ~> 
                {query-id, parent-id, tree-id, query-title}:document? = @document-from-state!

                # create a new copy of the document, update as required then save it to local storage
                {query-id, branch-id}:forked-document = {} <<< document <<< {
                    query-id: generate-uid!
                    parent-id: query-id
                    branch-id: \localFork
                    tree-id
                    query-title: "Fork of #{query-title}"
                }
                client-storage.save-document query-id, forked-document

                # by redirecting the user to a localFork branch we cause the document to be loaded from local-storage
                open-window "/branches/#{branch-id}/queries/#{query-id}", \_blank
              show: !config.high-security

            * label: \Clone
              action: ~> 
                {query-id, parent-id, tree-id, query-title}:document? = @document-from-state!

                # create a new copy of the document, update as required then save it to local storage
                {query-id, branch-id}:forked-document = {} <<< document <<< {
                    query-id: generate-uid!
                    parent-id: null
                    branch-id: \local
                    tree-id: null
                    query-title: "Clone of #{query-title}"
                }
                client-storage.save-document query-id, forked-document

                # by redirecting the user to a localFork branch we cause the document to be loaded from local-storage
                open-window "/branches/#{branch-id}/queries/#{query-id}", \_blank
              show: !config.high-security

            * label: \Save
              hotkey: "command + s"
              action: ~> @save!
              show: !config.high-security

            * label: \Cache
              highlight: if from-cache then 'rgba(0,255,0,1)' else null
              toggled: cache
              type: \toggle
              action: ~> @set-state {cache: !cache}

            * label: \Execute
              enabled: data-source-cue.complete
              hotkey: "command + enter"
              show: !executing-op
              action: ~> 
                @props.record do 
                    event-type: \execute-query
                    event-args: 
                        document: @document-from-state!
                @execute!

            * label: \Cancel
              show: !!executing-op
              action: ~> $.get "/apis/ops/#{executing-op}/cancel"

            * label: \Dispose
              show: !!@state.dispose
              action: ~> 
                @state.dispose!
                @set-state dispose: undefined

            * label: 'Data Source'
              pressed: \data-source-cue-popup == popup
              action: toggle-popup \data-source-cue-popup
              show: !config.high-security

            * label: \Parameters
              pressed: \parameters-popup == popup
              action: toggle-popup \parameters-popup

            * label: \Tags
              pressed: \tags-popup == popup
              action: toggle-popup \tags-popup
              show: !config.high-security

            * label: \Reset
              enabled: saved-query
              action: ~> 
                <~ @set-state (@state-from-document remote-document)
                @save-to-client-storage!

            * label: \Diff
              enabled: saved-query
              highlight: do ~>
                return null if !saved-query
                changes = @changes-made!
                return null if changes.length == 0
                return 'rgba(0,255,0,1)' if changes.length == 1 and changes.0 == \parameters
                'rgba(255,255,0,1)'
              action: ~> open-window "#{window.location.href}/diff", \_blank

            * label: \Share
              enabled: saved-query
              pressed: \share-popup == popup
              action: toggle-popup \share-popup

            * label: \Snapshot
              enabled:saved-query
              action: ~>
                  @save!.then ({branch-id, query-id}) ~>
                      $.get "/apis/branches/#{branch-id}/queries/#{query-id}/export/#{@state.cache}/png/1200/800?snapshot=true"

            * label: \VCS
              enabled: saved-query
              action: ~> open-window "#{window.location.href}/tree", \_blank

            * label: \Settings
              enabled: true
              action: (button-left) ~> @set-state {dialog: \settings}

            * label: 'Task Manager'
              href: \/ops
              action: ~> open-window "/ops", \_blank

        editors = 
            * editor-id: \query
              title: @state.query-title

            * editor-id: \transformation
              title: \Transformation

            * editor-id: \presentation
              title: \Presentation
            ...

        div {class-name: \query-route},

            # MENU
            Menu do 
                ref: \menu
                items: menu-items 
                    |> filter ({show}) -> (typeof show == \undefined) or show
                    |> map ({enabled}:item) -> {} <<< item <<< {enabled: (if typeof enabled == \undefined then true else enabled)}

                # PIPE LOGO
                Link do 
                    id: \logo
                    class-name: \logo
                    key: \logo
                    to: \/
                    on-click: (e) ~>
                        return if !!e.meta-key

                        if !!@state.dispose
                            @state.dispose!
                            @set-state dispose: undefined

                        if @should-prevent-reload! and !(confirm "You have NOT saved your query. Leave anyways")
                            e.prevent-default!
                            e.stop-propagation!

            # POPUPS
            # left-from-width :: Number -> Number
            left-from-width = (width) ~>
                x = popup-left - width / 2
                max-x = (x + width)
                diff = max-x - window.inner-width # react complains when using refs.ref.get-DOM-node!.viewport-width
                if diff > 0 then x - diff else x

            switch popup
            | \data-source-cue-popup =>
                DataSourceCuePopup do
                    left: left-from-width
                    data-source-cue: data-source-cue
                    on-change: (data-source-cue) ~> 
                        <~ @set-state {data-source-cue}
                        @save-to-client-storage-debounced!

            | \parameters-popup =>
                div do 
                    class-name: 'parameters-popup popup'
                    style: left: left-from-width 400
                    key: \parameters-popup
                    AceEditor do
                        editor-id: "parameters-editor"
                        value: @state.parameters
                        width: 400
                        height: 300
                        on-change: (value) ~> 
                            <~ @set-state parameters : value
                            @save-to-client-storage-debounced!

            | \share-popup =>
                {parameters, transpilation} = @document-from-state!
                [err, compiled-parameters] = pipe-web-client.compile-parameters-sync parameters, transpilation.query
                SharePopup do 
                    host: window.location.host
                    left: left-from-width
                    query-id: query-id
                    branch-id: branch-id
                    compiled-parameters: compiled-parameters
                    data-source-cue: data-source-cue

            | \tags-popup =>
                div do 
                    class-name: 'tags-popup popup'
                    style: 
                        left: left-from-width 400
                        width: 400
                        overflow: \visible
                    key: \tags-popup
                    MultiSelect do 
                        theme: \dark
                        create-from-search: (os, vs, search) ->   
                            return null if search.length == 0 or search in map (.label), ([] ++ (os ? []) ++ (vs ? []))
                            label: search, value: search
                        values: tags 
                        options: existing-tags
                        on-values-change: (tags, callback) ~> 
                            <~ @set-state {tags}
                            @save-to-client-storage-debounced!
                            callback!

            # DIALOGS
            if !!dialog
                div class-name: \dialog-container,
                    match dialog
                    | \new-query =>
                        NewQueryDialog do 
                            initial-data-source-cue: data-source-cue
                            initial-transpilation-language: transpilation-language
                            on-create: (data-source-cue, transpilation-language) ~>
                                (pipe-web-client.load-default-document data-source-cue, transpilation-language)
                                    .then (document) ~> @on-document-load document, document
                                    .catch (err) ~> alert "Unable to get default document for: #{data-source-cue?.query-type}/#{transpilation-language} (#{err})"
                                    .then ~> @set-state dialog: null

                    | \save-conflict =>
                        ConflictDialog do 
                            queries-in-between: queries-in-between
                            on-cancel: ~> @set-state dialog: null, queries-in-between: null
                            on-resolution-select: (resolution) ~>
                                uid = generate-uid!
                                match resolution
                                | \new-commit => @save-document {} <<< @document-from-state! <<< {query-id: uid, parent-id: queries-in-between.0, branch-id, tree-id}
                                | \fork => @save-document {} <<< @document-from-state! <<< {query-id: uid, parent-id: query-id, branch-id: uid, tree-id}
                                | \reset => @set-state (@state-from-document remote-document)
                                @set-state dialog: null, queries-in-between: null

                    | \settings =>
                        SettingsDialog do
                            initial-urls: @state.client-external-libs
                            initial-transpilation-language: transpilation-language
                            on-change: ({urls, transpilation-language}) ~>
                                @load-client-external-libs urls, @state.client-external-libs
                                @set-state do
                                    client-external-libs: urls
                                    dialog: null
                                    transpilation-language: transpilation-language
                                @save-to-client-storage-debounced!
                            on-cancel: ~> @set-state dialog: null
                        
            div class-name: \content,

                # EDITORS
                div do 
                    class-name: \editors
                    style: 
                        width: editor-width
                    [0 til editors.length] |> map (index) ~>

                        {editable-title, editor-id, title} = editors[index]

                        # get-editor-settings :: String -> AceEditorSettings
                        get-editor-settings = (editor-id) ~>
                            (ui-protocol[data-source-cue.query-type]?[camelize "#{editor-id}-editor-settings"] ? (->)) transpilation-language

                        # settings for the current editor
                        {show-editor, show-title}:editor-settings? = get-editor-settings editor-id

                        div do 
                            class-name: \editor
                            key: editor-id

                            # EDITABLE TITLE
                            if !!show-title
                                div do 
                                    {
                                        id: editor-id
                                        class-name: \editor-title
                                    } <<< (
                                        if !!(get-editor-settings editors?[index - 1]?.editor-id ?.show-editor)
                                            on-mouse-down: (e) ~>
                                                initialY = e.pageY
                                                initial-heights = <[transformation presentation query]>
                                                    |> map (p) ~> [p, @state[camelize "#{p}-editor-height"]]
                                                    |> pairs-to-obj
                                                $ window .on \mousemove, ({pageY}) ~> 
                                                    diff = pageY - initialY
                                                    match editor-id 
                                                    | \transformation =>
                                                        transformation-editor-height = initial-heights.transformation - diff
                                                        query-editor-height = initial-heights.query + diff
                                                        if transformation-editor-height > 0 and query-editor-height > 0
                                                            @set-state {transformation-editor-height, query-editor-height}
                                                    | \presentation =>
                                                        transformation-editor-height = initial-heights.transformation + diff
                                                        presentation-editor-height = initial-heights.presentation - diff
                                                        if transformation-editor-height > 0 and presentation-editor-height > 0
                                                            @set-state {transformation-editor-height, presentation-editor-height}
                                                $ window .on \mouseup, -> $ window .off \mousemove .off \mouseup
                                        else 
                                            {}
                                    )
                                    
                                    if editor-id == \query
                                        input do
                                            type: \text
                                            value: title
                                            on-change: ({current-target:{value}}) ~>
                                                <~ @set-state "#{editor-id}Title" : value
                                                @save-to-client-storage-debounced!
                                    else
                                        title

                            # ACE EDITOR
                            if !!show-editor
                                AceEditor do 
                                    {
                                        editor-id: "#{editor-id}-editor"
                                        value: @state[editor-id]
                                        width: @state.editor-width
                                        height: @state[camelize "#{editor-id}-editor-height"]
                                        on-change: (value) ~>
                                            <~ @set-state "#{editor-id}" : value
                                            @save-to-client-storage-debounced!
                                    } 
                                    <<< editor-settings
                                    <<< (
                                        if editor-id == \query
                                            on-click: ({dom-event:{meta-key}, editor}) -> 
                                                if !!meta-key
                                                    {row, column} = editor.get-cursor-position!
                                                    session = editor.get-session!
                                                    current-token = session.get-token-at row, column
                                                    previous-token = (session.get-tokens row)[current-token.index - 2]
                                                    if (dasherize previous-token?.value ? "") == \run-latest-query
                                                        branch-id = current-token.value.replace /\\|\"|\'/g, ""
                                                        open-window "/branches/#{branch-id}" 
                                        else
                                            {}
                                    )
                            

                # RESIZE HANDLE
                div do
                    class-name: \resize-handle
                    ref: \resize-handle
                    on-mouse-down: (e) ~>
                        initialX = e.pageX
                        initial-width = @state.editor-width
                        $ window .on \mousemove, ({pageX}) ~> 
                            <~ @set-state {editor-width: initial-width + (pageX - initialX)}
                            @update-presentation-size!
                        $ window .on \mouseup, -> $ window .off \mousemove .off \mouseup
                
                # PRESENTATION CONTAINER
                div do
                    ref: camelize \presentation-container
                    class-name: "presentation-container #{if !!executing-op then 'executing' else ''}"

                    # PRESENTATION: operations on this div are not controlled by react
                    div ref: \presentation, class-name: \presentation, id: \presentation

                    # STATUS BAR
                    if !!displayed-on
                        time-formatter = d3.time.format("%d %b %I:%M %p")
                        items = 
                            * title: 'Displayed on'
                              value: time-formatter new Date displayed-on
                            * title: 'From cache'
                              value: if from-cache then \Yes else \No
                              show: !execution-error
                            * title: 'Cached on'
                              value: time-formatter new Date execution-end-time
                              show: !execution-error and from-cache
                            * title: 'Execution time'
                              value: "#{execution-duration / 1000} seconds"
                              show: !execution-error
                        div do 
                            class-name: \status-bar
                            items 
                                |> filter -> (typeof it.show == \undefined) or !!it.show
                                |> map ({title, value}) ->
                                    div key: title,
                                        label null, title
                                        span null, value
    
    # React class method
    # get-initial-state :: a -> UIState
    get-initial-state: ->
        {
            cache: @props?.cache-query ? true # user checked the cache checkbox
            dialog: null # String (name of the dialog to display)
            executing-op: "" # String (alphanumeric op-id of the currently running query)
            from-cache: false # latest result is from-cache (it is returned by the server on execution)
            pending-client-external-libs: false
            popup: null # String (name of the popup to display)

            # TAGS POPUP
            existing-tags: [] # [String] (fetched from /apsi/tags)            

            # DOCUMENT
            query-id: null
            parent-id: null
            branch-id: null
            tree-id: null
            data-source-cue: @props.default-data-source-cue
            query: ""
            query-title: "Untitled query"
            transformation: ""
            presentation: ""
            parameters: ""
            tags: []
            editor-width: 550 
            keywords-from-query-result: []
            transpilation-language: @props.default-transpilation-language
            client-external-libs: []

        } <<< editor-heights!

    # React component life cycle method
    # component-did-mount :: a -> Void
    component-did-mount: !->

        # auto-completion for editors
        transformation-keywords = ([{}, require \prelude-ls] |> concat-map keywords-from-object) ++ alphabet
        presentation-keywords = ([{}, require \prelude-ls] |> concat-map keywords-from-object) ++ alphabet
        d3-keywords = keywords-from-object d3
        @default-completers =
            * get-completions: (editor, , , prefix, callback) ~>
                keywords-from-query-result = @state[camelize \keywords-from-query-result]
                range = editor.getSelectionRange!.clone!
                    ..set-start range.start.row, 0
                text = editor.session.get-text-range range
                [keywords, meta] = match editor.container.id
                    | \transformation-editor => [(unique <| transformation-keywords ++ keywords-from-query-result), \transformation]
                    | \presentation-editor => [(unique <| if /.*d3\.($|[\w-]+)$/i.test text then d3-keywords else presentation-keywords), \presentation]
                    | _ => [alphabet, editor.container.id]
                callback null, (convert-to-ace-keywords [keywords: keywords, score: 1], meta, prefix)
            ...
        ace-language-tools.set-completers @default-completers

        # auto completion for tags
        pipe-web-client.get-all-tags!.then (existing-tags) ~>
            @set-state do 
                existing-tags: ((@state.existing-tags ? []) ++ (existing-tags |> map -> label: it, value: it))
                    |> unique-by (.label)
                    |> sort-by (.label)

        # create a debounced version of save-to-local-storage
        @save-to-client-storage-debounced = _.debounce @save-to-client-storage, 350

        # crash recovery
        @unload-listener = (e) ~> 
            @save-to-client-storage!
            if @should-prevent-reload!
                message = "You have NOT saved your query. Stop and save if your want to keep your query."
                (e || window.event)?.return-value = message
                message
        
        window.add-event-listener \beforeunload, @unload-listener

        # update the size of the presentation on resize (based on size of editors)
        $ window .on \resize, ~> @update-presentation-size!
        @update-presentation-size!
                
        # request permission for push notifications
        if notifyjs.needs-permission
            notifyjs.request-permission!

        # selects presentation content only
        key 'command + a', (e) ~> 
            return true if e.target != document.body
            range = document.create-range!
                ..select-node-contents find-DOM-node @refs.presentation
            selection = window.get-selection!
                ..remove-all-ranges!
                ..add-range range
            cancel-event e

        # load the document based on the url
        @load @props

    # on-document-load :: Document -> Document -> Void
    on-document-load: (local-document, remote-document) ->

        # existing-tags must also include tags saved on client storage 
        existing-tags = (@state.existing-tags ? []) ++ ((local-document.tags ? []) |> map -> label: it, value: it)
            |> unique-by (.label)
            |> sort-by (.label)

        <~ @set-state {} <<< (@state-from-document local-document ? remote-document) <<< {remote-document, existing-tags}

        @save-to-client-storage!

        # create the auto-completer for ACE for the current data-source-cue
        @setup-query-auto-completion!

        # now that we know the editor width, we should update the presentation size
        @update-presentation-size!

        # redistribute the heights among the editors based on there visibility
        @set-state editor-heights.apply do
            @
            <[query transformation presentation]> |> map ~>
                {show-editor} = ui-protocol[@state.data-source-cue.query-type]?[camelize "#{it}-editor-settings"] @state.transpilation-language
                if !!show-editor then @state[camelize "#{it}-editor-height"] else 0

        {cache, execute}? = @props.location.query

        # update state.cache to the value (if any) present in the query string
        <~ do ~> (callback) ~> 
            if !!cache
                @set-state do 
                    cache: cache == \true
                    callback
            else 
                callback!

        <~ to-callback (@load-client-external-libs @state.client-external-libs, [])
        <~ set-timeout _, 1000

        # execute the query (if either config.auto-execute or query-string.execute is true)
        # only if there's no pending-client-external-libs (check component-did-update)
        if !!@props.auto-execute or execute == \true
            @execute!

    # React component life cycle method (invoked before props are set)
    # component-will-receive-props :: Props -> Void
    component-will-receive-props: (props) !->
        
        # return if branch & query id did not change
        return if props.params.branch-id == @props.params.branch-id and props.params.query-id == @props.params.query-id

        # return if the document with the new changes to props is already loaded
        # after saving the document we update the url (this prevents reloading the saved document from the server)
        return if props.params.branch-id == @state.branch-id and props.params.query-id == @state.query-id

        @load props

    # React component life cycle method (invoked after the render function)
    # updates the list of auto-completers if the data-source-cue has changed
    # component-did-update :: Props -> State -> Void
    component-did-update: (prev-props, prev-state) !->

        # call on-query-changed method, returned when setting up the auto-completer
        # this method uses the query to build the AST which is used internally to 
        # create the get-completions method for AceEditor
        do ~>
            if !!@on-query-changed-p and @state.query != prev-state.query
                @on-query-changed-p.then ~> it @state.query
        
        # auto-complete
        do ~>
            {data-source-cue, transpilation-language} = @state

            # return if the data-source-cue is not complete or there is no change in the data-source-cue
            if (data-source-cue.complete and !(data-source-cue `is-equal-to-object` prev-state.data-source-cue)) or transpilation-language != prev-state.transpilation-language
                @setup-query-auto-completion!

                # redistribute the heights among the editors based on there visibility
                @set-state editor-heights.apply do 
                    @
                    <[query transformation presentation]> |> map ~>
                        {show-editor} = ui-protocol[@state.data-source-cue.query-type]?[camelize "#{it}-editor-settings"] @state.transpilation-language
                        if !!show-editor then @state[camelize "#{it}-editor-height"] else 0

    # React component life cycle method
    # component-will-unmount :: a -> Void
    component-will-unmount: ->
        window.remove-event-listener \beforeunload, @unload-listener if !!@unload-listener

    # loads the document from local cache (if present) or server
    # invoked on page load or when the user changes the url
    # load :: Props -> Void
    load: (props) !->
        {branch-id, query-id}? = props.params

        # local branch only exists on the authors machine       
        local-branch = branch-id in <[local localFork]>
        
        if !!query-id
            
            # local-document :: Document
            local-document = client-storage.get-document query-id
            
            # :: (Promise p) => p document -> Void (State changes)
            update-state-using-document = (document-p) !~>
                document-p 
                .then (document) ~> @on-document-load local-document ? document, document
                .catch (err) ~> 
                    alert "Unable to get default document for: #{data-source-cue?.query-type}/#{transpilation-language}"
                    window.location.href = \/

            # eg: branches/local/queries/query-id
            if !!local-branch
                
                # we are on a local branch and the local-document is present
                # we can use the local-document.data-source-cue to get the default document (and use it as remote document)
                if !!local-document
                    {data-source-cue, transpilation-language}? = @state-from-document local-document
                    update-state-using-document (pipe-web-client.load-default-document data-source-cue, transpilation-language)

                # we are on a local branch and the local-document does not exist
                # this means its a new query, so we display the new query dialog
                else 
                    @set-state dialog: \new-query

            # load from local storage / remote
            # eg: branches/branch-id/queries/query-id
            else
                update-state-using-document pipe-web-client.load-query query-id

        else

            # handled by express, redirects the user to the latest query
            # eg: branches/local or branches/branch-id
            if !!branch-id 
                throw  "not implemented at client level, (refresh the page)"

            # this is the url used by 'New Query' button
            # it redirects user to branches/local/queries/query-id 
            # eg: branches/
            else
                @history.replace-state null, "/branches/local/queries/#{generate-uid!}"

    # load-client-external-libs :: [String] -> [String] -> p a
    load-client-external-libs: (next, prev) ->

        # remove urls from head
        (prev `difference` next) |> each ~>
            switch (last url.split \.)
            | \js => $ "head > script[src='#{url}'" .remove!
            | \css => $ "head > link[href='#{url}'" .remove!

        # add urls to head
        urls-to-add = next `difference` prev

        if urls-to-add.length > 0
            pipe-web-client.require-deps next

        else 
            new Promise (res) ~> res \done

    # SIDEEFFECT
    # uses @state.data-source-cue, @state.transpilation-language
    # adds @on-query-changed-p :: p (String -> p AST)
    # setup-query-auto-completion :: a -> Void
    setup-query-auto-completion: !->
        {data-source-cue, query, transpilation-language} = @state
        {query-type} = data-source-cue
        {make-auto-completer} = ui-protocol[query-type]

        # set the default completers (removing the currently set query completer if any)
        ace-language-tools.set-completers @default-completers

        # @on-query-changed-p :: p (String -> p AST)
        @on-query-changed-p = make-auto-completer (.container.id == \query-editor), [data-source-cue, transpilation-language] .then ({get-completions, on-query-changed}) ~>
            ace-language-tools.set-completers [{get-completions}] ++ @default-completers
            on-query-changed query
            on-query-changed    

    # update-presentation-size :: a -> Void
    update-presentation-size: !->
        left = @state.editor-width + 5
        (find-DOM-node @refs.presentation-container).style <<<
            left: left
            width: window.inner-width - left
            height: window.inner-height - (find-DOM-node @refs.menu).offset-height
    
    # execute :: a -> Void
    execute: !->

        if !!@state.executing-op
            return

        {query-id, branch-id, query-title, data-source-cue, query, 
        transformation, presentation, parameters, transpilation}:document-from-state = @document-from-state!
        
        compiled-parameters <~ compile-parameters parameters, transpilation.query .then _

        # process-query-result :: Result -> p (a -> Void)
        process-query-result = (result) ~>
            transformation-function <~ compile-transformation transformation, transpilation.transformation .then _
            presentation-function <~ compile-presentation presentation, transpilation.presentation .then _
            
            # execute the transformation code
            try
                transformed-result = transformation-function result, compiled-parameters
            catch ex
                return new Promise (, rej) -> rej "ERROR IN THE TRANSFORMATION EXECUTAION: #{ex.to-string!}"

            view = find-DOM-node @refs.presentation

            # if transformation returns a stream then listen to it and update the presentation
            if \Function == typeof! transformed-result.subscribe
                subscription = transformed-result.subscribe (e) -> presentation-function view, e, compiled-parameters
                Promise.resolve -> subscription.dispose!

            # otherwise invoke the presentation function once with the JSON returned from transformation
            else
                try
                    presentation-function view, transformed-result, compiled-parameters
                catch ex
                    return new Promise (, rej) -> rej "ERROR IN THE PRESENTATION EXECUTAION: #{ex.to-string!}"
                Promise.resolve null
        
        # dispose the result of any previous execution
        <~ do ~> (callback) ~>
            return callback! if !@state.dispose
            @state.dispose!
            @set-state {dispose: undefined}, callback

        # generate a unique op id
        op-id = generate-uid!

        # update the ui to reflect that an op is going to start
        @set-state executing-op: op-id

        err, {dispose, result-with-metadata}? <~ to-callback do ~>

            # clean existing presentation
            ($ find-DOM-node @refs.presentation).empty!

            # make the ajax request and process the query result
            op-info = document: document-from-state
            {result}:result-with-metadata <~ (pipe-web-client.execute do 
                data-source-cue
                query
                transpilation.query
                compiled-parameters
                @state.cache
                op-id
                op-info) .then

            # transform and visualize the result
            dispose <~ process-query-result result .then
            Promise.resolve {dispose, result-with-metadata}

        if !!err
            pre = $ "<pre/>"
            pre.html err.to-string!
            ($ find-DOM-node @refs.presentation).append pre
            @set-state execution-error: true
            @props.record do 
                event-type: \execution-error
                event-args: 
                    document: @document-from-state!
                    error: err

        else

            {result, from-cache, execution-end-time, execution-duration} = result-with-metadata

            # extract keywords from query result (for autocompletion in transformation)
            keywords-from-query-result = switch
                | is-type 'Array', result => result ? [] |> take 10 |> get-all-keys-recursively (-> true) |> unique
                | is-type 'Object', result => get-all-keys-recursively (-> true), result
                | _ => []

            # update the status bar below the presentation            
            <~ @set-state {from-cache, execution-end-time, execution-duration, keywords-from-query-result, dispose}

            # notify the user
            if document[\webkitHidden]
                notification = new notifyjs do 
                    'Pipe: query execution complete'
                    body: "Completed execution of (#{@state.query-title}) in #{@state.execution-duration / 1000} seconds"
                    notify-click: -> window.focus!
                notification.show!

        # update the ui to reflect that the op is complete
        @set-state displayed-on: Date.now!, executing-op: "" 

    # returns a list of document properties (from current UIState) that diverged from the remote document
    # changes-made :: a -> [String]
    changes-made: ->

        # there are no changes made if the query does not exist on the server 
        return [] if !@state.remote-document

        unsaved-document = @document-from-state!
        <[query transformation presentation parameters queryTitle dataSourceCue tags transpilation]>
            |> filter ~> !(unsaved-document?[it] `is-equal-to-object` @state.remote-document?[it])

    # converts the current UIState to Document & POST's it as a "save" request to the server
    # save :: (Promise p) => a -> p Document
    save: ->
        if @changes-made!.length == 0
            Promise.resolve @document-from-state!

        else 
            uid = generate-uid! 
            {query-id, tree-id, parent-id}:document = @document-from-state!

            # a new query-id is generated at the time of save, parent-id is set to the old query-id
            # expect in the case of a forked-query (whose parent-id is saved in the local-storage at the time of fork)
            @save-document do 
                {} <<< document <<<
                    query-id: uid
                    parent-id: switch @props.params.branch-id
                        | \local => null
                        | \localFork => parent-id
                        | _ => query-id
                    branch-id: if (@props.params.branch-id.index-of \local) == 0 then uid else @props.params.branch-id
                    tree-id: tree-id or uid

    # save-document :: (Promise p) => Document -> p Document
    save-document: (document-to-save) ->
        (pipe-web-client.save-document document-to-save)
            .then ({query-id, branch-id}:saved-document) ~>

                # update the local storage with the saved document
                client-storage.delete-document @props.params.query-id

                # update the state with saved-document
                @set-state {} <<< (@state-from-document saved-document) <<< remote-document: saved-document

                # update the url to point to the latest query id
                @history.replace-state null, "/branches/#{branch-id}/queries/#{query-id}"

                saved-document

            .catch (response-text) ~>

                [err, queries-in-between]? = do ->

                    # empty response
                    if !response-text
                        return [\empty-error]

                    # json parse error
                    try
                        {queries-in-between}? = JSON.parse response-text
                    
                    catch exception
                        return [\parse-error]

                    # local and remote queries are different
                    if !!queries-in-between
                        return [\save-conflict, queries-in-between]
                    
                    [\unknown-error]

                match err
                | \save-conflict => @set-state {dialog: \save-conflict, queries-in-between}
                | _ => alert "Error: #{err}, #{response-text}"

                throw err

    # true indicates the reload must be prevented
    # should-prevent-reload :: a -> Boolean
    should-prevent-reload: ->
        prevent-reload = 
            | @changes-made!.length > 0 =>
                @save-to-client-storage!
                true
            | _ => false
        @props.prevent-reload and prevent-reload

    # save to client storage only if the document has loaded
    # save-to-client-storage :: a -> Void
    save-to-client-storage: !-> 
        if !!@state.remote-document
            client-storage.save-document @props.params.query-id, @document-from-state!    
    
    # converting the document to a flat object makes it easy to work with 
    # state-from-document :: Document -> UIState
    state-from-document: ({
        query-id, parent-id, branch-id, tree-id, data-source-cue, query-title, query,
        transformation, presentation, parameters, ui, transpilation,
        client-external-libs, tags
    }?) ->
        {
            query-id, parent-id, branch-id, tree-id, data-source-cue, query-title, query
            transformation, presentation, parameters, 
            tags: (tags ? []) |> map ~> label: it, value: it
            editor-width: ui?.editor?.width or @state.editor-width
            transpilation-language: transpilation?.query ? \livescript
            client-external-libs: client-external-libs ? []
        } <<< editor-heights do 
            ui?.query-editor?.height or @state.query-editor-height
            ui?.transformation-editor?.height or @state.transformation-editor-height
            ui?.presentation-editor?.height or @state.presentation-editor-height

    # document-from-state :: a -> Document
    document-from-state: ->
        {
            query-id, parent-id, branch-id, tree-id, data-source-cue, query-title, query,
            transformation, presentation, parameters, editor-width, query-editor-height,
            transformation-editor-height, presentation-editor-height, transpilation-language, 
            client-external-libs, tags
        } = @state
        {
            query-id
            parent-id
            branch-id
            tree-id
            data-source-cue
            query-title
            transpilation:
                query: transpilation-language
                transformation: transpilation-language
                presentation: transpilation-language
            query
            transformation
            presentation
            tags: map (.label), tags
            client-external-libs
            parameters
            ui:
                editor:
                    width: editor-width
                query-editor:
                    height: query-editor-height
                transformation-editor:
                    height: transformation-editor-height
                presentation-editor:
                    height: presentation-editor-height
        }