import os
import re
import string
import textwrap

import arxiv
import gradio as gr
from fastapi import FastAPI
from fastapi.responses import RedirectResponse
from notion_client import Client


def clean_filename(filename):
    prefix = filename.split("]")[0] + "]"
    filename, ext = os.path.splitext(filename.replace(prefix, "").strip())

    # Remove leading/trailing whitespace
    filename = filename.strip()

    # Separate title from the filename
    if " " not in filename.split(":")[0]:
        splitted_filename = filename.split(":")
        title = splitted_filename[0]
        if title.islower():
            title = title.capitalize()
        remaining = ":".join(splitted_filename[1:]).strip()
        filename = f"({title}) {remaining}"

    # Remove punctuation marks and other special characters
    valid_chars = f"-_.()[] {string.ascii_letters}{string.digits}"
    filename = "".join(c if c in valid_chars else "_" for c in filename)

    # Add back the prefix
    filename = f"{prefix} {filename}"

    # Truncate the filename to 255 characters (max limit on some systems)
    filename = filename[: 255 - len(ext)]
    return f"{filename}{ext}"


databases = {}
prefix = "NOTION_DB_"
for k in os.environ.keys():
    if k.startswith(prefix):
        key = " ".join(x.capitalize() for x in k.replace(prefix, "").lower().split("_"))
        databases[key] = os.environ.get(k)


def add_notion_record(database, paper_id, title, published, url):
    notion = Client(auth=os.environ.get("NOTION_AUTH"))
    database_id = databases[database]
    new_data = {
        "FullName": {"rich_text": [{"text": {"content": title}}]},
        "Date": {"date": {"start": published}},
        "Arxiv": {"url": url},
    }
    if " " not in title.split(":")[0]:
        short_title = title.split(":")[0]
        if short_title.islower():
            short_title = short_title.capitalize()
        new_data["Name"] = {"title": [{"text": {"content": short_title}}]}
    try:
        notion.pages.create(
            parent={"database_id": database_id},
            properties=new_data,
        )
        print(f"Paper '{paper_id}' added to {database} DB successfully!")
    except Exception as err:
        print(err)


# with gr.Blocks(theme=gr.themes.Soft()) as io:
with gr.Blocks() as io:
    with gr.Column():
        input = gr.Textbox(label="URL")
        with gr.Row():
            btn_gen = gr.Button("Generate", variant="primary")
            btn_hide = gr.Button("Reset", visible=False)
    with gr.Column(visible=False) as actions:
        paper_title = gr.Textbox(label="Title")
        paper_published = gr.Textbox(label="Published")
        with gr.Row():
            paper_id = gr.Textbox(label="ID")
            paper_version = gr.Textbox(label="Version")
        paper_url = gr.Textbox(label="URL")
        paper_pdf = gr.Textbox(label="PDF URL")
        paper_fname = gr.Textbox(label="PDF filename")
        with gr.Row():
            rad_db = gr.Radio(list(databases.keys()), label="Notion Database")
            btn_add = gr.Button("Add to Notion", variant="primary")
            btn_add.click(
                add_notion_record,
                inputs=[rad_db, paper_id, paper_title, paper_published, paper_url],
            )
        with gr.Row():
            btn_view = gr.Button("Open Web Viewer")
            btn_down = gr.Button("Download PDF")

        btn_view.click(
            fn=None,
            inputs=[paper_pdf],
            _js=textwrap.dedent(
                """
                (url) => {
                    const linkUrl = "https://mozilla.github.io/pdf.js/web/viewer.html?file=" + url;
                    window.open(linkUrl, '_blank')
                }
                """
            ),
        )
        btn_down.click(
            fn=None,
            inputs=[paper_pdf, paper_fname],
            _js=textwrap.dedent(
                """
                async (url, name) => {
                    try {
                        const response = await fetch(url, { method: 'GET' });
                        const buffer = await response.arrayBuffer();
                        const blob = new Blob([buffer], { type: 'application/octet-stream' });
                        const blobUrl = window.URL.createObjectURL(blob);
                        const a = document.createElement('a');
                        a.href = blobUrl;
                        a.download = name;
                        document.body.appendChild(a);
                        a.click();
                        document.body.removeChild(a);
                        window.URL.revokeObjectURL(blobUrl);
                    } catch (error) {
                        console.error(error);
                    }
                }
                """
            ),
        )

    def get_info(url):
        pattern = r"([0-2])([0-9])(0|1)([0-9])\.[0-9]{4,5}(v[0-9]{1,2})?"
        match = re.search(pattern, url)

        assert match, "Wrong URL"

        info_id = match[0]

        search = arxiv.Search(id_list=[info_id])
        result = next(search.results())

        info_ver = result.entry_id[-2:]
        info_published = result.published.date()
        info_title = result.title
        info_url = f"https://arxiv.org/abs/{info_id}"
        info_pdf = f"https://arxiv.org/pdf/{info_id}{info_ver}.pdf"
        info_fname = clean_filename(f"[{info_id}{info_ver}] {info_title}.pdf")

        return {
            paper_id: gr.update(value=info_id),
            paper_version: gr.update(value=info_ver),
            paper_published: gr.update(value=info_published),
            paper_title: gr.update(value=info_title),
            paper_url: gr.update(value=info_url),
            paper_pdf: gr.update(value=info_pdf),
            paper_fname: gr.update(value=info_fname),
        }

    def show_actions():
        return {
            actions: gr.update(visible=True),
            btn_hide: gr.update(visible=True),
        }

    def hide_actions():
        return {
            actions: gr.update(visible=False),
            btn_hide: gr.update(visible=False),
        }

    btn_gen.click(
        lambda input: {**show_actions(), **get_info(input)},
        inputs=[input],
        outputs=[
            actions,
            btn_hide,
            paper_id,
            paper_version,
            paper_published,
            paper_title,
            paper_url,
            paper_pdf,
            paper_fname,
        ],
    )
    btn_hide.click(hide_actions, outputs=[actions, btn_hide])

io.launch(server_name="0.0.0.0")
