User = require '../models/user'
nodemailer = require 'nodemailer'
bcrypt = require 'bcrypt'

gmail = nodemailer.createTransport "SMTP", {
  service: "Gmail",
  auth: {
    user: process.env.EMAIL_USERNAME
    pass: process.env.EMAIL_PASSWORD
  }
}

generateValidationCode = ->
  letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
  code = ""
  for i in [0..7]
    code += letters[Math.floor Math.random()*letters.length]
  return code

exports.auth = (req, response, next) ->
  response.locals.userId = null
  loggedIn = ->
    console.log req.session
    response.locals.userId = req.session?.userId
    response.locals.admin = req.session?.admin
    return next()
  if req.session.userId? or ['/register', '/verify', '/forgot'].indexOf(req.path) isnt -1
    return loggedIn()
  render = (opts = {}) ->
    opts.err ?= null
    opts.data ?= {}
    opts.title = "Login"
    response.render 'login', opts
  if req.method is 'POST' and req.body.form is 'login' and req.body.email?
    # Check data
    {email, password} = req.body
    r = User.find(where:{email:email})
    r.error (err) ->
      return render({data:req.body,err})
    r.success (user) ->
      if !user
        return render {data:req.body,err:new Error()}
      bcrypt.compare password, user.password, (err, res) ->
        if err or !res
          return render {data:req.body,err:new Error()}
        else
          if user.approved?
            req.session.userId = user.id
            req.session.admin = user.admin
            return loggedIn()
          else
            subject = "Pending approval: account ##{user.id}"
            response.render 'message',
              title:"Awaiting approval"
              html:
                """
                <p>
                Our trustees need to enter you onto our Register of Members
                before your account can be approved. If it's been more than 5
                days, please contact <a
                href="mailto:trustees@somakeit.org.uk?subject=#{encodeURIComponent
                subject}">trustees@somakeit.org.uk</a>.
                </p>
                """
    return
  return render()

exports.verify = (req, response) ->
  {id, validationCode} = req.query ? {}
  id = parseInt(id, 10)
  validationCode = ""+validationCode
  fail = ->
    response.statusCode = 400
    response.render 'message', {title: "Invalid parameters", text: "Something went wrong - please check the email again."}
  success = ->
    response.render 'message', {title: "Validation complete", text: "Thanks! We'll be in touch shortly... "}
  if isNaN(id) or id <= 0 or validationCode.length isnt 8
    fail()
  else
    r = User.find(id)
    r.error (err) ->
      fail()
    r.success (user) ->
      if !user
        return fail()

      data = {}
      try
        data = JSON.parse user.data

      if !data.validationCode?
        success()
      else if data.validationCode is validationCode
        delete data.validationCode

        user.email = data.email ? user.email
        delete data.email
        delete data.validationCode
        user.data = JSON.stringify data

        r = user.save()
        r.error (err) ->
          console.error "Error saving validated user."
          console.error err
          response.render 'message', {title: "Database issue", text: "Please try again later."}
        r.success ->
          if user.approved?
            # XXX: email old address to tell them it has been replaced
            success()
          else
            approveURL = "http://members.somakeit.org.uk/user/#{user.id}"
            gmail.sendMail {
              from: "So Make It <web@somakeit.org.uk>"
              to: process.env.APPROVAL_TEAM_EMAIL
              subject: "SoMakeIt[Registration]: #{user.fullname} (#{user.email})"
              body: """
                New registration:

                  Email: #{user.email}
                  Name: #{user.fullname}
                  Address: #{("\n"+user.address).replace(/\n/g, "\n    ")}
                  Wikiname: #{user.wikiname}

                Approve or reject them here:
                #{approveURL}

                Thanks,

                The So Make It web team
                """
            }, (err, res) ->
              success()
      else
        fail()

exports.forgot = (req, response) ->
  if req.session?.userId
    response.redirect "/"
    return
  render = (opts = {}) ->
    opts.err ?= null
    opts.data ?= {}
    opts.title = "Forgot Password"
    response.render 'forgot', opts
  success = ->
    response.render 'message', {title:"Success", text: "Password reset."}
  sent = ->
    response.render 'message', {title:"Password Reset Sent", text: "Please check your email for your reset code."}
  if req.method isnt 'POST'
    if req.query.id
      render({password:true})
    else
      render()
  else
    unless req.body.email? or req.query.id?
      return render()
    if req.query.id?
      id = parseInt(req.query.id, 10)
      r = User.find(id)
      r.error (err) ->
        response.render 'message', {title:"Error", text: "Unknown error occurred, please try again later."}
      r.success (user) ->
        if !user
          response.render 'message', {title:"Error", text: "User not found"}
          return
        data = {}
        try
          data = JSON.parse user.data
        if data.resetCode isnt req.query.validationCode or !data.resetCode or (data.passwordResetRequested ? 0) < (new Date().getTime() - 24*60*60*1000)
          response.render 'message', {title:"Denied", text: "Password reset expired."}
          return
        error = new Error()
        unless req.body.password?.length >= 6
          error.password = true
        unless req.body.password is req.body.password2
          error.password = true
          error.passwordsdontmatch = true
        if error.password
          render({password:true, err})
          return
        delete data.resetCode
        delete data.passwordResetRequested
        user.data = JSON.stringify data
        bcrypt.hash req.body.password, 10, (err, hash) ->
          if err or !hash
            response.render 'message', {title:"error", text: "unknown error occurred, please try again later."}
            return
          user.password = hash
          r = user.save()
          r.error (err) ->
            response.render 'message', {title:"error", text: "unknown error occurred, please try again later."}
          r.success ->
            success()

    else if req.body.email?
      r = User.find(where:{email:req.body.email})
      r.error (err) ->
        return render({data:req.body,err})
      r.success (user) ->
        if !user
          gmail.sendMail {
            from: "So Make It <web@somakeit.org.uk>"
            to: req.body.email
            subject: "So Make It reset"
            body: """
              Someone (hopefully you) attempted to reset the password for this
              account, however we don't have an account at this email address -
              sorry about that. Do you have any other addresses you may have
              used?

              Cheers,

              The So Make It web team.
              """
            }, (err, res) ->
              sent()
        else
          validationCode = generateValidationCode()
          data = {}
          try
            data = JSON.parse user.data
          data.resetCode = validationCode
          data.passwordResetRequested = new Date().getTime()
          user.data = JSON.stringify data
          r = user.save()
          r.error (err) ->

          verifyURL = "#{process.env.SERVER_ADDRESS}/forgot?id=#{user.id}&validationCode=#{validationCode}"
          r.success ->
            gmail.sendMail {
              from: "So Make It <web@somakeit.org.uk>"
              to: req.body.email
              subject: "So Make It password reset"
              body: """
                Please click the link below to reset your password:

                #{verifyURL}

                Cheers,

                The So Make It web team.
                """
              }, (err, res) ->
                sent()

exports.register = (req, response) ->
  if req.session?.userId
    response.redirect "/"
    return
  render = (opts = {}) ->
    opts.err ?= null
    opts.data ?= {}
    opts.title = "Register"
    response.render 'register', opts
  if req.method is 'POST' and req.body.form is 'register'
    error = new Error()
    unless /^[^@\s,"]+@[^@\s,]+\.[^@\s,]+$/.test req.body.email ? ""
      error.email = true
    unless /.+ .*/.test req.body.fullname ? ""
      error.fullname = true
    unless req.body.address?.length > 8
      error.address = true
    unless req.body.terms is 'on'
      error.terms = true
    unless req.body.password?.length >= 6
      error.password = true
    unless req.body.password is req.body.password2
      error.password = true
      error.passwordsdontmatch = true
    if error.email or error.fullname or error.address or error.terms or error.password
      render(err:error, data: req.body)
    else
      # Attempt registration
      validationCode = generateValidationCode()
      bcrypt.hash req.body.password, 10, (err, hash) ->
        if err
          return fail()
        r = User.create {
          email: req.body.email
          password: hash
          fullname: req.body.fullname
          address: req.body.address
          wikiname: req.body.wikiname ? null
          data: JSON.stringify {
            email: req.body.email
            validationCode: validationCode
          }
        }
        r.success (user) ->
          # Send them the email
          verifyURL = "#{process.env.SERVER_ADDRESS}/verify?id=#{user.id}&validationCode=#{validationCode}"
          gmail.sendMail {
            from: "So Make It <web@somakeit.org.uk>"
            to: req.body.email
            subject: "SoMakeIt: verify your email address"
            body: """
              Thanks for registering! Please verify your email address by clicking the link below:

              #{verifyURL}

              Thanks,

              The So Make It web team
              """
          }, (err, res) ->
            if err
              console.error "Error sending registration email."
              console.error err
            response.render 'registrationComplete', {title:"Registration complete", email: req.body.email, err: err}
        r.error (err) ->
          console.error "Error registering user:"
          console.error err
          if err.code is 'ER_DUP_ENTRY'
            err.email = true
            err.email409 = true
          else
            err.unknown = true
          render(err: err, data: req.body)
    return


  render()
