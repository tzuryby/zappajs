# **Zappa** is a [CoffeeScript](http://coffeescript.org) DSL-ish interface for building web apps on the
# [node.js](http://nodejs.org) runtime, integrating [express](http://expressjs.com), [socket.io](http://socket.io)
# and other best-of-breed libraries.

zappa = version: '0.4.0'

codename = 'Wowie Zowie'

log = console.log
fs = require 'fs'
path = require 'path'
express = require 'express'
socketio = require 'socket.io'
jquery = fs.readFileSync(__dirname + '/../vendor/jquery-1.7.2.min.js').toString()
sammy = fs.readFileSync(__dirname + '/../vendor/sammy-0.7.1.min.js').toString()
uglify = require 'uglify-js'

# Soft dependencies:
jsdom = null

# CoffeeScript-generated JavaScript may contain anyone of these; when we "rewrite"
# a function (see below) though, it loses access to its parent scope, and consequently to
# any helpers it might need. So we need to reintroduce these helpers manually inside any
# "rewritten" function.
coffeescript_helpers = """
  var __slice = Array.prototype.slice;
  var __hasProp = Object.prototype.hasOwnProperty;
  var __bind = function(fn, me){ return function(){ return fn.apply(me, arguments); }; };
  var __extends = function(child, parent) {
    for (var key in parent) { if (__hasProp.call(parent, key)) child[key] = parent[key]; }
    function ctor() { this.constructor = child; }
    ctor.prototype = parent.prototype; child.prototype = new ctor; child.__super__ = parent.prototype;
    return child; };
  var __indexOf = Array.prototype.indexOf || function(item) {
    for (var i = 0, l = this.length; i < l; i++) {
      if (this[i] === item) return i;
    } return -1; };
""".replace /\n/g, ''

minify = (js) ->
  ast = uglify.parser.parse(js)
  ast = uglify.uglify.ast_mangle(ast)
  ast = uglify.uglify.ast_squeeze(ast)
  uglify.uglify.gen_code(ast)

# Shallow copy attributes from `sources` (array of objects) to `recipient`.
# Does NOT overwrite attributes already present in `recipient`.
copy_data_to = (recipient, sources) ->
  for obj in sources
    for k, v of obj
      recipient[k] = v unless recipient[k]

# Takes in a function and builds express/socket.io apps based on the rules contained in it.
zappa.app = (func,options) ->
  context = {zappa, express}

  context.root = path.dirname(module.parent.filename)

  # Storage for user-provided stuff.
  # Views are kept at the module level.
  ws_handlers = {}
  helpers = {}
  postrenders = {}

  app = context.app = express()
  if options.https?
    app.server = require('https').createServer options.https, app
  else
    app.server = require('http').createServer app
  io = if options.disable_io then null else context.io = socketio.listen(app.server)

  # Reference to the zappa client, the value will be set later.
  client = null

  # Tracks if the zappa middleware is already mounted (`@use 'zappa'`).
  zappa_used = no

  # Force view-cache (so that we can populate it).
  unless options.export_views
    app.enable 'view cache'

  # Provide register (as in Express 2)
  compilers = {}
  register = (ext,obj) ->
    if ext[0] isnt '.'
      ext = '.' + ext
    compile = obj.compile
    if not compile
      throw new Error "register #{ext} must provide a .compile"
    # Register the compiler so that context.view may use it.
    compilers[ext] = compile
    # Register it with Express natively.
    renderFile = (path,options,next) ->
      renderFile[path] ?= compile fs.readFileSync(path,options.encoding ? 'utf8'), options
      next null, renderFile[path] options
    app.engine ext, renderFile

  # Zappa's default settings.
  app.set 'view engine', 'coffee'
  register '.coffee', zappa.adapter require('coffeecup').adapters.express,
      blacklist: ['format', 'autoescape', 'locals', 'hardcode', 'cache']

  # Sets default view dir to @root (`path.dirname(module.parent.filename)`).
  app.set 'views', path.join(context.root, '/views')

  for verb in ['get', 'post', 'put', 'del']
    do (verb) ->
      context[verb] = (args...) ->
        arity = args.length
        if arity > 1
          route
            verb: verb
            path: args[0]
            middleware: args[1...arity-1]
            handler: args[arity-1]
        else
          for k, v of arguments[0]
            route verb: verb, path: k, handler: v

  context.client = (obj) ->
    context.use 'zappa' unless zappa_used
    for k, v of obj
      js = ";zappa.run(#{v});"
      js = minify(js) if app.settings['minify']
      route verb: 'get', path: k, handler: js, contentType: 'js'

  context.coffee = (obj) ->
    for k, v of obj
      js = ";#{coffeescript_helpers}(#{v})();"
      js = minify(js) if app.settings['minify']
      route verb: 'get', path: k, handler: js, contentType: 'js'

  context.js = (obj) ->
    for k, v of obj
      js = String(v)
      js = minify(js) if app.settings['minify']
      route verb: 'get', path: k, handler: js, contentType: 'js'

  context.css = (obj) ->
    for k, v of obj
      css = String(v)
      route verb: 'get', path: k, handler: css, contentType: 'css'

  if typeof options.require_css is 'string'
    options.require_css = [options.require_css]
  for name in options.require_css
    context[name] = (obj) ->
      for k, v of obj
        css = require(name).render v, filename: k, (err, css) ->
          throw err if err
          route verb: 'get', path: k, handler: css, contentType: 'css'

  context.helper = (obj) ->
    for k, v of obj
      helpers[k] = v

  context.postrender = (obj) ->
    jsdom = require 'jsdom'
    for k, v of obj
      postrenders[k] = v

  context.on = (obj) ->
    for k, v of obj
      ws_handlers[k] = v

  context.view = (obj) ->
    for k, v of obj
      ext = path.extname(k)
      if not ext
        ext = '.' + app.get 'view engine'
        kl = k + ext

      if options.export_views
        # Support both foo.bar and foo
        loc = path.join( app.get('views'), options.export_views, k )
        fs.writeFileSync loc, v
        if kl
          loc = path.join( app.get('views'), options.export_views, kl )
          fs.writeFileSync loc, v
      else
        compile = compilers[ext]
        if not compile?
          compile = compilers[ext] = require(ext.slice 1).compile
        if not compile?
          throw new Error "Cannot find a compiler for #{ext}"
        r =
          render: (options,next) ->
            r.cache ?= compile v, options
            next null, r.cache options

        # Support both foo.bar and foo
        app.cache[k] = r
        if kl
          app.cache[kl] = r

  context.register = (obj) ->
    for k, v of obj
      register '.' + k, v

  context.set = (obj) ->
    for k, v of obj
      app.set k, v

  context.enable = ->
    app.enable i for i in arguments

  context.disable = ->
    app.disable i for i in arguments

  context.use = ->
    zappa_middleware =
      static: (p = path.join(context.root, '/public')) ->
        express.static(p)
      zappa: ->
        (req, res, next) ->
          send = (code) ->
            res.contentType 'js'
            res.send code
          if req.method.toUpperCase() isnt 'GET' then next()
          else
            switch req.url
              when '/zappa/zappa.js' then send client
              when '/zappa/jquery.js' then send jquery
              when '/zappa/sammy.js' then send sammy
              else next()

    use = (name, arg = null) ->
      zappa_used = yes if name is 'zappa'

      if zappa_middleware[name]
        app.use zappa_middleware[name](arg)
      else if typeof express[name] is 'function'
        app.use express[name](arg)

    for a in arguments
      switch typeof a
        when 'function' then app.use a
        when 'string' then use a
        when 'object'
          if a.stack? or a.route?
            app.use a
          else
            use k, v for k, v of a

  context.configure = (p) ->
    if typeof p is 'function' then app.configure p
    else app.configure k, v for k, v of p

  context.settings = app.settings

  context.shared = (obj) ->
    context.use 'zappa' unless zappa_used
    for k, v of obj
      js = ";zappa.run(#{v});"
      js = minify(js) if app.settings['minify']
      route verb: 'get', path: k, handler: js, contentType: 'js'
      v.apply(context, [context])

  context.include = (p) ->
    sub = if typeof p is 'string' then require path.join(context.root, p) else p
    sub.include.apply(context, [context])

  apply_helpers = (ctx) ->
    for name, helper of helpers
      do (name, helper) ->
        if typeof helper is 'function'
          ctx[name] = (args...) ->
            args.push ctx
            helper.apply ctx, args
        else
          ctx[name] = helper
    ctx

  # Register a route with express.
  route = (r) ->
    r.middleware ?= []

    # Rewrite middleware
    r.middleware = r.middleware.map (f) ->
      (req,res,next) ->
        ctx =
          app: app
          settings: app.settings
          request: req
          query: req.query
          params: req.params
          body: req.body
          session: req.session
          response: res
          next: next

        apply_helpers ctx

        if app.settings['databag']
          data = {}
          copy_data_to data, [req.query, req.params, req.body]

        switch app.settings['databag']
          when 'this' then f.apply(data, [ctx])
          when 'param' then f.apply(ctx, [data])
          else result = f.apply(ctx, [ctx])

    if typeof r.handler is 'string'
      app[r.verb] r.path, r.middleware..., (req, res) ->
        res.contentType r.contentType if r.contentType?
        res.send r.handler
    else
      app[r.verb] r.path, r.middleware..., (req, res, next) ->
        ctx =
          app: app
          settings: app.settings
          request: req
          query: req.query
          params: req.params
          body: req.body
          session: req.session
          response: res
          next: next
          send: -> res.send.apply res, arguments
          json: -> res.json.apply res, arguments
          redirect: -> res.redirect.apply res, arguments
          render: ->
            if typeof arguments[0] isnt 'object'
              render.apply @, arguments
            else
              for k, v of arguments[0]
                render.apply @, [k, v]

        render = (name,opts,next) ->

          # Make sure the second arg is an object.
          if typeof opts is 'function'
            next = opts
            opts = {}

          if app.settings['databag']
            opts.params = data

          if not opts.postrender?
            postrender = next
          else
            postrender = (err, str) ->
              if err then return next err
              # Apply postrender before sending response.
              jsdom.env html: str, src: [jquery], done: (err, window) ->
                if err then return next err
                ctx.window = window
                rendered = postrenders[opts.postrender].apply(ctx, [window.$, ctx])

                doctype = (window.document.doctype or '') + "\n"
                html = doctype + window.document.documentElement.outerHTML
                if next?
                  next null, html
                else
                  res.send.call res, html

          if opts.layout is false
            layout = postrender
          else
            # Use the default layout if one isn't given, or layout: true
            if opts.layout is true or not opts.layout?
              opts.layout = 'layout'
            layout = (err,str) ->
              if err then return next err
              opts.body = str
              res.render.call res, opts.layout, opts, postrender

          res.render.call res, name, opts, layout

        apply_helpers ctx

        if app.settings['databag']
          data = {}
          copy_data_to data, [req.query, req.params, req.body]

        # Go!
        switch app.settings['databag']
          when 'this' then result = r.handler.apply(data, [ctx])
          when 'param' then result = r.handler.apply(ctx, [data])
          else result = r.handler.apply(ctx, [ctx])

        res.contentType(r.contentType) if r.contentType?
        if typeof result is 'string' then res.send result
        else return result

  # Register socket.io handlers.
  io?.sockets.on 'connection', (socket) ->
    c = {}

    build_ctx = ->
      ctx =
        app: app
        io: io
        settings: app.settings
        socket: socket
        id: socket.id
        client: c
        join: (room) ->
          socket.join room
        leave: (room) ->
          socket.leave room
        emit: ->
          if typeof arguments[0] isnt 'object'
            socket.emit.apply socket, arguments
          else
            for k, v of arguments[0]
              socket.emit.apply socket, [k, v]
        broadcast: ->
          if typeof arguments[0] isnt 'object'
            socket.broadcast.emit.apply socket.broadcast, arguments
          else
            for k, v of arguments[0]
              socket.broadcast.emit.apply socket.broadcast, [k, v]
        broadcast_to: (room, args...) ->
          if typeof args[0] isnt 'object'
            socket.broadcast.to(room).emit.apply socket.broadcast, args
          else
            for k, v of args[0]
              socket.broadcast.to(room).emit.apply socket.broadcast, [k, v]
        broadcast_to_all: (room, args...) ->
          if typeof args[0] isnt 'object'
            socket.broadcast.to(room).emit.apply socket.broadcast, args
            socket.emit.apply socket, args
          else
            for k, v of args[0]
              socket.broadcast.to(room).emit.apply socket.broadcast, [k, v]
              socket.emit.apply socket, [k, v]

      apply_helpers ctx
      ctx

    ctx = build_ctx()
    ws_handlers.connection.apply(ctx, [ctx]) if ws_handlers.connection?

    socket.on 'disconnect', ->
      ctx = build_ctx()
      ws_handlers.disconnect.apply(ctx, [ctx]) if ws_handlers.disconnect?

    for name, h of ws_handlers
      do (name, h) ->
        if name isnt 'connection' and name isnt 'disconnect'
          socket.on name, (data, ack) ->
            ctx = build_ctx()
            ctx.data = data
            ctx.ack = ack
            switch app.settings['databag']
              when 'this' then h.apply(data, [ctx])
              when 'param' then h.apply(ctx, [data])
              else h.apply(ctx, [ctx])

  # Go!
  func.apply(context, [context])

  # The stringified zappa client.
  client = require('./client').build(zappa.version, app.settings)
  client = ";#{coffeescript_helpers}(#{client})();"
  client = minify(client) if app.settings['minify']

  if app.settings['default layout']
    context.view layout: ->
      doctype 5
      html ->
        head ->
          title @title if @title
          if @scripts
            for s in @scripts
              script src: s + '.js'
          script(src: @script + '.js') if @script
          if @stylesheets
            for s in @stylesheets
              link rel: 'stylesheet', href: s + '.css'
          link(rel: 'stylesheet', href: @stylesheet + '.css') if @stylesheet
          style @style if @style
        body @body

  context

# zappa.run [host,] [port,] [{options},] root_function
# Takes a function and runs it as a zappa app. Optionally accepts a port number, and/or
# a hostname (any order). The hostname must be a string, and the port number must be
# castable as a number.
# Returns an object where `app` is the express server and `io` is the socket.io handle.
zappa.run = ->
  host = null
  port = 3000
  root_function = null
  options =
    disable_io: false
    require_css: ['stylus']

  for a in arguments
    switch typeof a
      when 'string'
        if isNaN( (Number) a ) then host = a
        else port = (Number) a
      when 'number' then port = a
      when 'function' then root_function = a
      when 'object'
        for k, v of a
          switch k
            when 'host' then host = v
            when 'port' then port = v
            when 'css' then options.require_css = v
            when 'disable_io' then options.disable_io = v
            when 'https' then options.https = v

  zapp = zappa.app(root_function,options)
  app = zapp.app

  if host
    app.server.listen port, host
  else
    app.server.listen port

  log 'Express server listening on port %d in %s mode',
    app.server.address()?.port, app.settings.env

  log "Zappa #{zappa.version} \"#{codename}\" orchestrating the show"

  zapp

# Creates a zappa view adapter for templating engine `engine`. This adapter
# can be used with `context.register` and creates params "shortcuts".
# 
# Zappa, by default, automatically sends all request params to templates,
# but inside the `params` local.
#
# This adapter adds a "root local" for each of these params, *only* 
# if a local with the same name doesn't exist already, *and* the name is not
# in the optional blacklist.
#
# The blacklist is useful to prevent request params from triggering unset
# template engine options.
#
# If `engine` is a string, the adapter will use `require(engine)`. Otherwise,
# it will assume the `engine` param is an object with a `compile` function.
zappa.adapter = (engine, options = {}) ->
  options.blacklist ?= []
  engine = require(engine) if typeof engine is 'string'
  compile: (template, data) ->
    template = engine.compile(template, data)
    (data) ->
      for k, v of data.params
        if typeof data[k] is 'undefined' and k not in options.blacklist
          data[k] = v
      template(data)

module.exports = zappa.run
module.exports.run = zappa.run
module.exports.app = zappa.app
module.exports.adapter = zappa.adapter
module.exports.version = zappa.version
