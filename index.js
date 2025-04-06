const puppeteer = require('puppeteer');
// const parser = require('rss-url-parser');
const { XMLParser, XMLBuilder, XMLValidator } = require("fast-xml-parser");
const fs = require('fs');

const { QuickDB } = require("quick.db");
const db = new QuickDB();

const Koa = require('koa');
const Router = require('@koa/router');

const { bodyParser } = require("@koa/bodyparser");

const app = new Koa();
app.use(bodyParser());
const router = new Router();

const parser = new XMLParser();

// Logger middleware
app.use(async (ctx, next) => {
  const start = Date.now();
  await next();
  const ms = Date.now() - start;
  console.log(`${ctx.method} ${ctx.url} - ${ms}ms`);
});



router.get('/getBooks/:id', async (ctx) => {
  const user_id = ctx.params.id
  try {
    let XMLdata;
    await fetch('https://www.goodreads.com/review/list_rss/' + user_id + '').then(response => response.text()).then(data => XMLdata = data);

    let jObj = parser.parse(XMLdata);
    let [books, shelves] = booksCleaner(jObj.rss.channel.item);

    let nb_books = jObj.rss.channel.item.length;
    let page = 1;
    while(nb_books == 100){
	page++;
	await fetch('https://www.goodreads.com/review/list_rss/' + user_id + '?page=' + page).then(response => response.text()).then(data => XMLdata = data);
	let jObj = parser.parse(XMLdata);
	let [temp_books, temp_shelves] = booksCleaner(jObj.rss.channel.item);
	nb_books = jObj.rss.channel.item.lenght;

	books = books.concat(temp_books);
	temp_shelves.forEach(shelve => {
            if (!shelves.includes(shelve)) {
	        shelves.push(shelve);
            }
        });
    }

    ctx.status = 200;
    ctx.body = { 'books': books, 'shelves': shelves }
  } catch (error) {
    ctx.status = 500;
    ctx.body = { message: error.message };
  }
});

function booksCleaner(books) {
  let cleanedBooks = []
  let shelves = ['all']
  books.forEach((book) => {
    cleanedBooks.push({
      title: book.title.toString(),
      id: book.book_id,
      shelve: book.user_shelves,
      author: book.author_name,
    })

    let temp = book.user_shelves.split(',').map(shelve => shelve.trim());

    temp.forEach(shelve => {
      if (!shelves.includes(shelve)) {
        shelves.push(shelve)
      }
    });
  });

  console.log(cleanedBooks);
  cleanedBooks.sort((a, b) => {
    return a.title.localeCompare(b.title);
  });




  return [cleanedBooks, shelves]
}


// https://example.com/connect?user=####&pass=####&force=false
router.get('/connect', async (ctx) => {
  const { user, pass } = ctx.query;
  if (user == undefined || pass == undefined) {
    ctx.status = 400;
    ctx.body = { message: "Missing user or pass" }
    return
  }
  const decrypted_password = decodePassword(pass);


  if (fs.existsSync('./sessions/' + user)) {
    fs.rmdirSync('./sessions/' + user, { recursive: true });
  }
  const browser = await puppeteer.launch({ headless: false, userDataDir: "./sessions/" + user });
  const page = await browser.newPage();

  try {
    await page.setUserAgent("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/44.0.2403.157 Safari/537.36");
    await page.goto('https://www.goodreads.com/user/sign_in');
    await page.setViewport({ width: 1080, height: 1024 });
    await page.locator('.authPortalSignInButton').click();
    await page.locator('#ap_email.auth-required-field').fill(user);
    await page.locator('#ap_password.auth-required-field').fill(pass);
    await page.locator('#signInSubmit').click();

    // Get href 
    const href_elem = await page.locator('.dropdown__trigger--profileMenu').waitHandle();
    const href = await href_elem.evaluate(el => el.href);
    // Get user id
    const user_id = href.split('/').pop().split('-')[0];
    db.set(user_id, { 'user': user, 'pass': pass });

    await browser.close();

    ctx.status = 200;
    ctx.body = { 'user_id': user_id }
  } catch (error) {
    browser.close();
    if (fs.existsSync('./sessions/' + user))
      fs.rmdirSync('./sessions/' + user, { recursive: true });

    if (db.set(user_id) != undefined)
      db.delete(user_id);

    ctx.status = 500;
    ctx.body = { message: error.message }
  }
});

router.post('/syncBooks', async (ctx) => {

  console.log(ctx.request);
  console.log(ctx.request.body);
  const { user_id, books_id, books_progress } = ctx.request.body;
  const user = await db.get(user_id);


  if (user == undefined) {
    ctx.status = 404;
    ctx.body = { message: "User not found" }
    return
  } else if (books_id == undefined || books_id.length == 0) {
    ctx.status = 400;
    ctx.body = { message: "Missing books id" }
    return
  } else if (books_progress == undefined || books_progress.length != books_id.length) {
    ctx.status = 400;
    ctx.body = { message: "Missing books progress" }
    return
  }

  try {
    const browser = await puppeteer.launch({ headless: true, userDataDir: "./sessions/" + user.user });
    const page = await browser.newPage();
    await page.setUserAgent("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/44.0.2403.157 Safari/537.36");
    await page.goto('https://www.goodreads.com/user/show/' + user_id);
    const cookies = await page.cookies();
    const csrf_token_elem = await page.locator('meta[name="csrf-token"]').waitHandle();
    const csrf_token = await csrf_token_elem.evaluate(el => el.content);

    let successes = 0;
    let error_msg = "";

    for (let i = 0; i < books_id.length; i++) {
      await fetch("https://www.goodreads.com/user_status.json", {
        "headers": {
          "accept": "*/*",
          "accept-language": "en-GB,en;q=0.9,pt-PT;q=0.8,pt;q=0.7,en-US;q=0.6,gl;q=0.5,ko;q=0.4",
          "cache-control": "no-cache",
          "content-type": "application/x-www-form-urlencoded; charset=UTF-8",
          "pragma": "no-cache",
          "sec-ch-ua": "\"Chromium\";v=\"128\", \"Not;A=Brand\";v=\"24\", \"Google Chrome\";v=\"128\"",
          "sec-ch-ua-mobile": "?0",
          "sec-ch-ua-platform": "\"Windows\"",
          "sec-fetch-dest": "empty",
          "sec-fetch-mode": "cors",
          "sec-fetch-site": "same-origin",
          "x-csrf-token": csrf_token,
          "x-requested-with": "XMLHttpRequest",
          "cookie": cookies.map(cookie => cookie.name + "=" + cookie.value).join("; "),
          "Referer": "https://www.goodreads.com/",
          "Referrer-Policy": "strict-origin-when-cross-origin"
        },
        "body": "user_status%5Bbook_id%5D=" + books_id[i] + "&user_status%5Bbody%5D=&user_status%5Bpercent%5D=" + books_progress[i],
        "method": "POST"
      }).then(
        response => {
          console.log(response);
          if (response.status == 200) {
            successes++;
          } else {
            error_msg = "Error on Book " + books_id[i] + "\n " + response.statusText;
          }
        });
    };

    await browser.close();
    ctx.status = 200;
    if (error_msg != "") {
      ctx.body = { message: "Synced " + successes + " Books successfully\n" + error_msg }
    } else {
      ctx.body = { message: "Synced " + successes + " Books successfully" }
    }
  } catch (error) {
    console.log(error);
    ctx.status = 500;
    ctx.body = { message: error.message }
  }

});

app.use(router.routes())
  .use(router.allowedMethods());

// Start the server
const port = 3000;
app.listen(port, () => {
  console.log(`Server running at http://localhost:${port}`);
});


// To be improved to something truely encrypted
function decodePassword(password) {
  const inverted_cipher_map = {
    '0': 'N',
    '1': 'U',
    '2': 'E',
    '3': 'p',
    '4': 'i',
    '5': 'S',
    '6': 'Z',
    '7': 'f',
    '8': '4',
    '9': 'c',
    N: '0',
    i: '1',
    T: '2',
    F: '3',
    V: '5',
    L: '6',
    k: '7',
    I: '8',
    z: '9',
    a: 'T',
    b: 'L',
    c: 'h',
    d: 'G',
    e: 'r',
    f: 'R',
    g: 'O',
    h: 'b',
    j: 'P',
    l: 'H',
    m: 'W',
    n: 'v',
    o: 'a',
    p: 'I',
    q: 't',
    r: 'Q',
    s: 'A',
    t: 'z',
    u: 'V',
    v: 'j',
    w: 'u',
    x: 's',
    y: 'M',
    A: 'k',
    B: 'F',
    C: 'K',
    D: 'B',
    E: 'm',
    G: 'd',
    H: 'D',
    J: 'x',
    K: 'C',
    M: 'g',
    O: 'o',
    P: 'l',
    Q: 'y',
    R: 'Y',
    S: 'n',
    U: 'q',
    W: 'X',
    X: 'J',
    Y: 'e',
    Z: 'w'
  }
  const decrypted_password = password.split('').map(char => { return inverted_cipher_map[char] || char }).join('');
  return decrypted_password
}
