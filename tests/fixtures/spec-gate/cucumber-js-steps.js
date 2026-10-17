const { Given } = require('@cucumber/cucumber');
Given('a shop', function () {});
Given('count {int}', function (n) { if (n === 2) throw new Error('boom'); });
Given('dup step', function () {});
Given(/^dup step$/, function () {});
Given('pend', function () { return 'pending'; });
