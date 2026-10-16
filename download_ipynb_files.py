# import os
# import sys
# import requests

# # 1. Configuration
# # Update CANVAS_BASE_URL if your ODU Canvas uses a different domain
# CANVAS_BASE_URL = "https://canvas.odu.edu"
# COURSE_ID = "213074"  # <-- Replace with your actual Canvas Course ID
# """Download a Canvas course's .ipynb files into the current working folder.

# Install: python -m pip install requests
# Set COURSE_ID below, then run: python download_canvas_notebooks.py
# The API token is read only from CANVAS_ODU_API_KEY.

# API documentation:
# https://developerdocs.instructure.com/services/canvas/resources/files
# https://developerdocs.instructure.com/services/canvas/basics/file.pagination
# """

import json
import os
import re
import sys
import tempfile
from pathlib import Path
from urllib.parse import urljoin, urlsplit

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry


# -------------------- SETTINGS --------------------
CANVAS_BASE_URL = "https://canvas.odu.edu"
COURSE_ID = "213074"
OUTPUT_DIR = Path.cwd()  # The folder from which you run this script.
# --------------------------------------------------

TIMEOUT = (15, 120)  # Connect timeout and read timeout, in seconds.


def origin(url):
    """Validate an HTTPS URL and return its normalized origin."""
    parsed = urlsplit(url)
    if (parsed.scheme != "https" or not parsed.hostname
            or parsed.username is not None or parsed.password is not None):
        raise ValueError("Use a valid HTTPS URL without embedded credentials.")
    return parsed.hostname.lower(), parsed.port or 443


def make_session():
    session = requests.Session()
    retries = Retry(
        total=4,
        backoff_factor=1,
        status_forcelist=(429, 500, 502, 503, 504),
        allowed_methods=("GET",),
        respect_retry_after_header=True,
        raise_on_status=False,
    )
    session.mount("https://", HTTPAdapter(max_retries=retries))
    # Do not put the Canvas token in session-wide headers.
    return session


def course_files(session, base_url, course_id, token):
    """Yield all files from all pages of the course-wide Files API."""
    url = f"{base_url}/api/v1/courses/{course_id}/files"
    params = {"per_page": 100}
    visited = set()

    while url:
        if origin(url) != origin(base_url):
            raise RuntimeError("Canvas returned a pagination URL on another host.")
        if url in visited:
            raise RuntimeError("Canvas repeated a pagination URL; listing stopped.")
        visited.add(url)

        with session.get(
            url,
            headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
            params=params,
            timeout=TIMEOUT,
            allow_redirects=False,
        ) as response:
            if 300 <= response.status_code < 400:
                raise RuntimeError(
                    "The API redirected. Set CANVAS_BASE_URL to the host shown "
                    "in your browser when viewing the course."
                )
            response.raise_for_status()
            try:
                page = response.json()
            except ValueError:
                raise RuntimeError(
                    "Canvas did not return JSON. Check the Canvas URL."
                ) from None
            if not isinstance(page, list):
                raise RuntimeError("Canvas returned an unexpected file-list response.")
            next_url = response.links.get("next", {}).get("url")
            url = urljoin(response.url, next_url) if next_url else None

        yield from page
        params = None  # The next-page URL already contains its query parameters.


def notebook_name(file_info):
    """Use the display name, falling back to Canvas's stored filename."""
    for key in ("display_name", "filename"):
        name = file_info.get(key) or ""
        if name.lower().endswith(".ipynb"):
            return name
    return None


def choose_destination(folder, name, file_id, used_names):
    """Flatten folders and choose a Windows-compatible, unused filename."""
    name = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", name)
    stem = name[:-6].strip(" .") or "notebook"
    stem = stem.encode("utf-8")[:160].decode("utf-8", errors="ignore")
    if re.fullmatch(
        r"CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9]",
        stem.split(".")[0],
        re.I,
    ):
        stem = "_" + stem

    candidate = folder / f"{stem}.ipynb"
    number = 0
    while candidate.name.casefold() in used_names or candidate.exists():
        number += 1
        suffix = f"__canvas_{file_id}" + (
            f"_{number}" if number > 1 else ""
        )
        candidate = folder / f"{stem}{suffix}.ipynb"
    used_names.add(candidate.name.casefold())
    return candidate


def download_file(session, file_info, destination, base_url, token):
    """Stream to a temporary file, check notebook JSON, then save it."""
    url = file_info.get("url")
    if not url:
        raise RuntimeError("Canvas did not provide a download URL for this file.")
    headers = {}
    if origin(url) == origin(base_url):
        headers["Authorization"] = f"Bearer {token}"
    # Signed storage URLs receive no Canvas token. Requests also removes the
    # Authorization header when a download redirects to a different host.

    temporary_path = None
    try:
        with session.get(
            url,
            headers=headers,
            stream=True,
            timeout=TIMEOUT,
        ) as response:
            response.raise_for_status()
            content_type = response.headers.get("Content-Type", "").lower()
            if "text/html" in content_type:
                raise RuntimeError(
                    "Received an HTML page instead of a notebook."
                )
            with tempfile.NamedTemporaryFile(
                mode="wb",
                dir=destination.parent,
                suffix=".part",
                delete=False,
            ) as output:
                temporary_path = Path(output.name)
                for chunk in response.iter_content(chunk_size=1024 * 1024):
                    if chunk:
                        output.write(chunk)

        # Check the response without changing the downloaded bytes.
        try:
            with temporary_path.open(
                "r",
                encoding="utf-8-sig",
            ) as downloaded:
                notebook = json.load(downloaded)
        except (ValueError, UnicodeError):
            raise RuntimeError(
                "Downloaded content is not valid notebook JSON."
            ) from None
        if (
            not isinstance(notebook, dict)
            or not isinstance(notebook.get("nbformat"), int)
        ):
            raise RuntimeError("Downloaded JSON is not a Jupyter notebook.")

        if destination.exists():
            raise RuntimeError(
                "The destination appeared during download; it was not replaced."
            )
        temporary_path.rename(destination)
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def error_message(error):
    """Do not print request URLs, which may contain signed credentials."""
    if isinstance(error, requests.HTTPError):
        status = (
            error.response.status_code
            if error.response is not None
            else "unknown"
        )
        hints = {
            401: (
                "Check CANVAS_ODU_API_KEY; "
                "the token may be invalid or expired."
            ),
            403: (
                "Access denied. "
                "Check course/file permissions and token scopes."
            ),
            404: (
                "Not found. Check the Canvas URL and course ID, "
                "or file availability."
            ),
            429: "Canvas rate limit reached. Try again later.",
        }
        return (
            f"HTTP {status}. "
            f"{hints.get(status, 'The server could not complete the request.')}"
        )
    if isinstance(error, requests.RequestException):
        return f"Network request failed ({type(error).__name__})."
    return str(error)


def main():
    token = os.environ.get("CANVAS_ODU_API_KEY", "").strip()
    if not token:
        raise RuntimeError(
            "The CANVAS_ODU_API_KEY environment variable is missing or empty."
        )

    course_id = str(COURSE_ID).strip()
    if (
        not course_id.isascii()
        or not course_id.isdigit()
        or int(course_id) <= 0
    ):
        raise ValueError(
            "Set COURSE_ID to the numeric ID in your Canvas course URL."
        )

    base_url = CANVAS_BASE_URL.strip().rstrip("/")
    origin(base_url)
    if (
        urlsplit(base_url).path
        or urlsplit(base_url).query
        or urlsplit(base_url).fragment
    ):
        raise ValueError(
            "CANVAS_BASE_URL must contain only the host, "
            "without /courses/... or /api/v1."
        )

    folder = Path(OUTPUT_DIR).resolve()
    folder.mkdir(parents=True, exist_ok=True)

    with make_session() as session:
        print(f"Finding notebooks in Canvas course {course_id}...")
        notebooks = {}
        for file_info in course_files(
            session,
            base_url,
            course_id,
            token,
        ):
            if notebook_name(file_info):
                # Deduplicate by Canvas file ID.
                notebooks[file_info["id"]] = file_info

        print(
            f"Found {len(notebooks)} notebook(s). "
            f"Destination: {folder}"
        )

        used_names = {
            path.name.casefold()
            for path in folder.iterdir()
        }
        downloaded = failed = 0

        for index, file_info in enumerate(
            notebooks.values(),
            start=1,
        ):
            destination = choose_destination(
                folder,
                notebook_name(file_info),
                file_info["id"],
                used_names,
            )
            try:
                download_file(
                    session,
                    file_info,
                    destination,
                    base_url,
                    token,
                )
                downloaded += 1
                print(
                    f"[{index}/{len(notebooks)}] "
                    f"Saved: {destination.name}"
                )
            except (
                requests.RequestException,
                OSError,
                ValueError,
                RuntimeError,
            ) as error:
                failed += 1
                print(
                    f"[{index}/{len(notebooks)}] "
                    f"FAILED: {destination.name}: {error_message(error)}"
                )

        print(
            f"\nFinished. Downloaded: {downloaded}; "
            f"failed: {failed}."
        )
        return 1 if failed else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nCanceled.", file=sys.stderr)
        sys.exit(130)
    except (
        requests.RequestException,
        OSError,
        ValueError,
        RuntimeError,
    ) as error:
        print(
            f"ERROR: {error_message(error)}",
            file=sys.stderr,
        )
        sys.exit(1)