# Text::Nunjucks

A faithful Perl port of Mozilla's [Nunjucks](https://mozilla.github.io/nunjucks/)
templating engine — same templates, same context, same output as Nunjucks
v3.2.4.

**Status: work in progress.** Nothing is usable yet.

## Development

```bash
maint/fetch-upstream          # pinned upstream checkout -> upstream/ (needs node)
echo '{"template":"{{ 1/3 }}"}' | node maint/oracle.js   # what does upstream do?
prove -lr t/                  # the suite (-r is mandatory)
```

Decisions about how JavaScript semantics map to Perl are recorded in `docs/adr/`.

## License

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.
