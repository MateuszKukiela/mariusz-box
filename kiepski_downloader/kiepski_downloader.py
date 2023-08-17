import urllib.request
import urllib.error
import os
import errno
from typing import Dict, Tuple, List, Optional


def read_env_file(filename: str) -> Dict[str, str]:
    """
    Read a .env file and return the configuration as a dictionary.
    """
    with open(filename, "r") as env_file:
        env = env_file.read().split("\n")

    ENV = {}
    for line in env:
        line = line.split("=")
        if len(line) == 2:
            ENV[line[0]] = line[1]

    return ENV


def read_episodes(filename: str) -> Dict[int, List[Tuple[str, str]]]:
    """
    Read the episodes from a text file and return them as a dictionary,
    with season number as the key and a list of episode tuples (episode_title, episode_url) as the value.
    """
    with open(filename, "r") as file:
        lines = file.readlines()

    episodes = {}
    season = None
    episode_title = None

    for line in lines:
        line = line.strip()
        if "SEZON" in line.upper():
            season = int(line.split()[-1])
            episodes[season] = []
        elif line:
            if episode_title is None:
                # This line is expected to be the episode title
                episode_title = line.split(". ", 1)[-1].strip()
            else:
                # This line is expected to be the episode URL
                episode_url = line
                episodes[season].append((episode_title, episode_url))
                episode_title = None  # Reset for next episode

    return episodes


def download_episode(season: int, episode_number: int, episode_info: Tuple[str, str], path: str) -> None:
    """
    Download the episode if it doesn't exist in the path.
    """
    episode_title, episode_url = episode_info

    try:
        file_path = f"{os.path.join(path, f'tv/Swiat wedlug Kiepskich/Season {season:02}', f'S{season:02}E{episode_number:03} - {episode_title}')}.mp4"

        if not os.path.exists(os.path.dirname(file_path)):
            try:
                os.makedirs(os.path.dirname(file_path))
            except OSError as exc:
                if exc.errno != errno.EEXIST:
                    raise

        if not os.path.isfile(file_path):
            print(f"Downloading {episode_title}")
            urllib.request.urlretrieve(episode_url, file_path)

    except urllib.error.HTTPError as e:
        print(f"HTTP Error for {episode_title}: {e.code} - {e.reason}")
    except urllib.error.URLError as e:
        print(f"URL Error for {episode_title}: {e.reason}")
    except Exception as e:
        print(f"Failed to download {episode_title}: {e}")


def main() -> None:
    env = read_env_file("../.env")
    path = env["ROOT_MEDIA"]
    episodes = read_episodes("episodes.txt")

    for season, episode_list in episodes.items():
        for episode_number, episode_info in enumerate(episode_list, 1):
            download_episode(season, episode_number, episode_info, path)


if __name__ == "__main__":
    main()
