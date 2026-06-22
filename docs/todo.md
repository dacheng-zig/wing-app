# todo
- [ ] form validation / validators component
- [ ] authentication / authorization middleware and User Component (Guest / Authenticated / Authorized based on Permission or Claim)
- [ ] catchAll middleware: when system is under maintenance
- [ ] db pool DX: 手动从连接池中租一个连接然后释放；lease.handle()->conn->query() IDE 无跳转；改进方向：用户直接面向 conn 操作，conn 内部自动维护 pool lease
- [ ] user repo 为何需要维护2个 gpa：一个在 init() 中维护，另一个通过业务方法传入