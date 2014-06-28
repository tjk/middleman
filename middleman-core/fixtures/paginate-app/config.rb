collection(where: 'blog/2011-{remaining}').per_page(5) do |items, num|
  proxy "/2011/pages/#{num}.html", "/archive/2011/index.html", locals: { items: items }
end
