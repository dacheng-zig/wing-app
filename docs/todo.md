# todo
- [-] authentication / authorization middleware and User Component (Guest / Authenticated / Authorized based on Permission or Claim)
  * object-level authz (BOLA) is a documented service-layer pattern (design §5), ready to apply once a mutable-object endpoint exists.
  * token resolver: ~~session~~ / ~~api token~~ / jwt / paseto
- [-] openapi doc
  * 错误响应 schema（待 validator RFC 9457）
  * 多状态码/oneOf/webhooks
- strong and generic ID type for global use: primary / foreign key (可解决id错误赋值引发的bug：如把 user id 赋值给 order id)
- [ ] form validation / validators component
- wing-app 框架版本控制，业务代码与框架代码隔离
- wing-jobs: web ui
- wing-auth mod
- wing-oauth: google, apple, facebook, twitter (x), qq, weixin, alipay
- wing-mailer: imap / smtp / pop3
- wing-cache: cache vtable and supports variable storage like: redis, memcached, db, file, memory
